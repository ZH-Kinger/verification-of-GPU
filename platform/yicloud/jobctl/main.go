// jobctl: 用官方 openapi-sdk-go 操作仪电智算云：提交/查看/停止验收任务、开发机、GPFS、对象存储。
//
//	jobctl submit <name> <node|any> <payload_dir> [KEY=VAL ...]   打包 payload_dir 进命令，单副本 8 卡，钉到指定节点
//	jobctl get <jobId> | replicas <jobId> | logs <jobId> [sinceMin] | stop <jobId> | list
//
// 环境: YICLOUD_* 来自 ~/.yicloud/env；PROJECT/ZONE/QUOTA 下面写死为本次验收的值。
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"gitee.com/yicloud-team/openapi-sdk-go/base"
	"gitee.com/yicloud-team/openapi-sdk-go/base/auth"
	"gitee.com/yicloud-team/openapi-sdk-go/base/config"
	"gitee.com/yicloud-team/openapi-sdk-go/base/msgs"
	"gitee.com/yicloud-team/openapi-sdk-go/services/fs"
	"gitee.com/yicloud-team/openapi-sdk-go/services/job"
)

// 本次验收的环境，均可用环境变量覆盖（YC_PROJECT / YC_ZONE / YC_QUOTA / YC_POOL / YC_IMAGE / YC_GPFS）。
var (
	project = mustEnv("YC_PROJECT")
	zone    = envOr("YC_ZONE", "cn-shanghai-a")
	quota   = envOr("YC_QUOTA", "gpu_task")
	pool    = envOr("YC_POOL", "gpu_task")
	// 默认镜像必须是 CUDA 12：tools/bin 的 gpu_burn / nccl-tests 链接 libcudart.so.12 / libcublas.so.12，
	// 用 CUDA 13 镜像时它们启动即 exit=127（曾导致 18h 长稳 1 秒结束）。
	image   = envOr("YC_IMAGE", "registry.gate.yicloud.com.cn/library/pytorch-training-nvidia:2.6.0-py3.10-cuda12.9-h20-ubuntu22.04-v20260710")
	gpfsSrc = envOr("YC_GPFS", "gpfs://gpfs8/acceptance")
)

func p[T any](v T) *T { return &v }

// 平台的 generate_distributed_job_envs.sh 在 DISTRIBUTED_JOB=true 时因 SOCKET_IP 含 127.0.1.1 直接 FATAL。
// DIST=0 时不设该变量（与控制台建的 test-copy 一致），分布式环境由我们自己在容器内建立。
func distEnv() map[string]string {
	if os.Getenv("DIST") == "0" {
		return map[string]string{"ACCEPTANCE": "multinode"}
	}
	return map[string]string{"DISTRIBUTED_JOB": "true"}
}

func mustEnv(k string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	fmt.Fprintf(os.Stderr, "error: 需要设置环境变量 %s\n", k)
	os.Exit(2)
	return ""
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

var dieMeta = func() {}

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	dieMeta()
	os.Exit(1)
}

func show(v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(b))
}

// packDir 把目录打成 tar.gz 再 base64，嵌进启动命令（节点无外网、存储未就绪时传脚本的办法）
func packDir(dir string) string {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	entries, err := os.ReadDir(dir)
	if err != nil {
		die(err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			die(err)
		}
		tw.WriteHeader(&tar.Header{Name: e.Name(), Mode: 0o755, Size: int64(len(data))})
		tw.Write(data)
	}
	tw.Close()
	gz.Close()
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func main() {
	cli := base.NewClient(base.WithConfig(config.New()), base.WithCredential(auth.NewCredential()))
	job.UseClient(cli)
	ctx, meta := msgs.NewMetaCtx()
	defer func() {}()
	dieMeta = func() {
		if meta != nil {
			fmt.Fprintf(os.Stderr, "request-id=%s detail=%v\n", meta.RequestID, meta.Err)
		}
	}
	if len(os.Args) < 2 {
		die(fmt.Errorf("usage: see header"))
	}
	switch os.Args[1] {
	case "submit":
		name, node, dir := os.Args[2], os.Args[3], os.Args[4]
		env := map[string]string{}
		for _, kv := range os.Args[5:] {
			k, v, _ := strings.Cut(kv, "=")
			env[k] = v
		}
		payload := packDir(dir)
		cmd := fmt.Sprintf("mkdir -p /tmp && cd /tmp && echo %s | base64 -d | tar xz && bash /tmp/probe.sh", payload)
		spec := job.CreateJobReqTaskSpec{
			Command:            []string{"bash", "-c", cmd},
			Env:                env,
			Image:              p(envOr("IMAGE", image)),
			Replicas:           p(1),
			GPU:                p("8"),
			CPU:                p("160"),
			Memory:             p("1600Gi"),
			RestartPolicy:      p("Never"),
			MaxRunningDuration: p("6h"),
		}
		if node != "any" {
			spec.PositiveTags = []string{"node/" + node}
		}
		req := &job.CreateJobReq{
			Name:               p(name),
			Project:            p(project),
			ZoneId:             p(zone),
			QuotaGroup:         p(quota),
			PoolName:           p(pool),
			TaskSpecs:          map[string]job.CreateJobReqTaskSpec{"t0": spec},
			BackoffLimit:       p(1),
			AutoDeleteDuration: p("168h"),
		}
		if os.Getenv("DRY") == "1" {
			r := *req
			s := spec
			s.Command = []string{"bash", "-c", fmt.Sprintf("<payload %d bytes b64> ...", len(payload))}
			r.TaskSpecs = map[string]job.CreateJobReqTaskSpec{"t0": s}
			show(r)
			return
		}
		d, err := job.CreateJob(ctx, req)
		if err != nil {
			die(err)
		}
		show(d)
	case "hold":
		// jobctl hold <name> <replicas> <hours>：起 N 副本 × 8 卡，只 sleep，开 SSH + 宿主机网络，测试经 SSH 进行
		name := os.Args[2]
		n, _ := strconv.Atoi(os.Args[3])
		hours := os.Args[4]
		spec := job.CreateJobReqTaskSpec{
			Command:     []string{"bash", "-c", "sleep " + hours + "h"},
			Env:         distEnv(),
			Image:       p(envOr("IMAGE", image)),
			Replicas:    p(n),
			GPU:         p(envOr("GPU", "8")),
			CPU:         p(envOr("CPU", "160")),
			Memory:      p(envOr("MEM", "1600Gi")),
			EnableSSHD:  p(envOr("SSH", "1") == "1"),
			HostNetwork: p(envOr("HOSTNET", "1") == "1"),

			RestartPolicy:      p("Never"),
			MaxRunningDuration: p(hours + "h"),
		}
		req := &job.CreateJobReq{
			Name: p(name), Project: p(project), ZoneId: p(zone), QuotaGroup: p(quota), PoolName: p(pool),
			TaskSpecs:    map[string]job.CreateJobReqTaskSpec{envOr("TASK", "worker"): spec},
			BackoffLimit: p(1), AutoDeleteDuration: p("168h"), EnableSSHD: p(envOr("SSH", "1") == "1"),
			FailurePolicy: p("CloseAllTasks"),
		}
		if os.Getenv("PRIVATE") == "1" {
			req.UsePrivateMachine = p(true)
		}
		switch os.Getenv("SKU") {
		case "tenant":
			req.SKUPrivate, req.SKUPrivateTenant = p(true), p(true)
		case "project":
			req.SKUPrivate, req.SKUPrivateProject = p(true), p(true)
		case "nopool":
			req.PoolName = nil
		}
		if envOr("GPFS", "1") == "1" {
			t := req.TaskSpecs[envOr("TASK", "worker")]
			t.MountGPFS = p(gpfsSrc + ":/mnt/acceptance")
			t.MountGpfsVolumes = []job.CreateJobReqMountGpfsVolume{{Source: p(gpfsSrc), Target: p("/mnt/acceptance")}}
			req.TaskSpecs[envOr("TASK", "worker")] = t
		}
		if os.Getenv("DRY") == "1" {
			show(req)
			return
		}
		d, err := job.CreateJob(ctx, req)
		if err != nil {
			die(err)
		}
		show(d)
	case "run":
		// jobctl run <name> <image> <cmd...>：单副本 8 卡训练任务，挂 GPFS，不设 DISTRIBUTED_JOB
		name, img := os.Args[2], os.Args[3]
		cmd := strings.Join(os.Args[4:], " ")
		spec := job.CreateJobReqTaskSpec{
			Command: []string{"bash", "-c", cmd}, Env: map[string]string{"ACCEPTANCE": "registry"},
			Image: p(img), Replicas: p(1), GPU: p(envOr("GPU", "8")), CPU: p(envOr("CPU", "176")), Memory: p(envOr("MEM", "1900Gi")),
			RestartPolicy: p("Never"), MaxRunningDuration: p(envOr("MAXRUN", "3h")), EnableSSHD: p(true),
			MountGPFS:        p(gpfsSrc + ":/mnt/acceptance"),
			MountGpfsVolumes: []job.CreateJobReqMountGpfsVolume{{Source: p(gpfsSrc), Target: p("/mnt/acceptance")}},
		}
		if n := os.Getenv("NODE"); n != "" {
			spec.PositiveTags = []string{"node/" + n}
		}
		req := &job.CreateJobReq{Name: p(name), Project: p(project), ZoneId: p(zone), QuotaGroup: p(quota), PoolName: p(pool),
			TaskSpecs: map[string]job.CreateJobReqTaskSpec{"worker": spec}, BackoffLimit: p(1), AutoDeleteDuration: p("168h"), EnableSSHD: p(true)}
		d, err := job.CreateJob(ctx, req)
		if err != nil {
			die(err)
		}
		show(d)
	case "mkbucket":
		// jobctl mkbucket <name> <TiB>
		rsp := msgs.Rsp[map[string]any]{}
		tib, _ := strconv.Atoi(os.Args[3])
		body := map[string]any{"Bucket": os.Args[2], "Project": project, "Capacity": tib << 40, "Description": "GPU 验收：对象存储性能测试"}
		if err := cli.Post(ctx, "/oss/v1alpha1/CreateBucket", body, &rsp); err != nil {
			die(err)
		}
		show(rsp.Data)
	case "get":
		d, err := job.GetJob(ctx, &job.GetJobReq{Project: p(project), JobId: p(os.Args[2])})
		if err != nil {
			die(err)
		}
		fmt.Printf("%s phase=%s msg=%q restarts=%d created=%s\n", d.JobId, d.Phase, d.Message, d.RestartCount, d.CreationTime)
	case "mkfs":
		// jobctl mkfs <name> <TiB>
		fs.UseClient(base.NewClient(base.WithConfig(config.New()), base.WithCredential(auth.NewCredential())))
		tib, _ := strconv.Atoi(os.Args[3])
		req := &fs.CreateFilesetWithQuotaReq{
			Name: p(os.Args[2]), Capacity: p(tib << 40), FS: p("GPFS"), FsCluster: p(envOr("YC_GPFS_CLUSTER", "gpfs8")),
			Project: p(project), ZoneId: p(zone), Description: p("GPU 验收：存储性能测试与测试工具/结果存放"),
		}
		if os.Getenv("DRY") == "1" {
			show(req)
			return
		}
		if err := fs.CreateFilesetWithQuota(ctx, req); err != nil {
			die(err)
		}
		fmt.Println("created fileset", os.Args[2])
	case "replicas":
		d, err := job.ListJobReplicas(ctx, &job.ListJobReplicasReq{Project: p(project), JobId: p(os.Args[2])})
		if err != nil {
			die(err)
		}
		for _, r := range d.Items {
			fmt.Printf("%s phase=%s node=%s ip=%s gpu=%s cpu=%s mem=%s start=%s end=%s\n", r.Name, r.Phase, r.NodeName, r.PodIP, r.GPU, r.CPU, r.Memory, r.CreationTime, r.EndTime)
		}
	case "logs":
		since := 360
		if len(os.Args) > 3 {
			since, _ = strconv.Atoi(os.Args[3])
		}
		end := time.Now()
		start := end.Add(-time.Duration(since) * time.Minute)
		var all []job.LogEntry
		cursor := start.UnixNano()
		for page := 0; page < 200; page++ {
			d, err := job.GetLogs(ctx, &job.GetLogsReq{Project: p(project), JobId: p(os.Args[2]),
				Start: p(int(cursor)), End: p(int(end.UnixNano())), Limit: p(5000), Direction: p("forward")})
			if err != nil {
				die(err)
			}
			if len(d.Items) == 0 {
				break
			}
			all = append(all, d.Items...)
			last, _ := strconv.ParseInt(d.Items[len(d.Items)-1].Timestamp, 10, 64)
			if len(d.Items) < 5000 || last <= cursor {
				break
			}
			cursor = last + 1
		}
		sort.SliceStable(all, func(i, j int) bool { return all[i].Timestamp < all[j].Timestamp })
		for _, e := range all {
			fmt.Println(e.Line)
		}
	case "stop":
		if err := job.StopJob(ctx, &job.StopJobReq{Project: p(project), JobId: p(os.Args[2]), ZoneId: p(zone)}); err != nil {
			die(err)
		}
		fmt.Println("stopped", os.Args[2])
	case "delete":
		var res []job.BatchDeleteJobsReqResourceIdentifier
		for _, id := range os.Args[2:] {
			res = append(res, job.BatchDeleteJobsReqResourceIdentifier{JobId: p(id), Project: p(project)})
		}
		if err := job.BatchDeleteJobs(ctx, &job.BatchDeleteJobsReq{Resources: res}); err != nil {
			die(err)
		}
		fmt.Println("deleted", len(res), "jobs")
	case "ws-create":
		// jobctl ws-create <name>：8 卡整机开发机，挂 GPFS。SDK 的 workspace 包编译不过，直接走 base client
		mount := map[string]string{"Source": gpfsSrc, "Target": "/mnt/acceptance"}
		req := map[string]any{
			"Name": os.Args[2], "Project": project, "ZoneId": zone, "QuotaGroup": quota,
			"GPU": envOr("GPU", "8"), "CPU": envOr("CPU", "176"), "Memory": envOr("MEM", "1900Gi"),
			"Image": image, "UsePrivateMachine": envOr("PRIVATE", "1") == "1", "Description": "GPU 验收",
			"RuntimeMode": envOr("RUNTIME", ""),
			"MountGPFS":   gpfsSrc + ":/mnt/acceptance", "MountGpfsVolumes": []map[string]string{mount},
			"SystemDisk": map[string]string{"Name": os.Args[2] + "-sys", "Storage": envOr("SYSDISK", "200Gi"), "DataSourceType": "Default"},
		}
		if os.Getenv("DRY") == "1" {
			show(req)
			return
		}
		rsp := msgs.Rsp[map[string]any]{}
		if err := cli.Post(ctx, "/workspace/v1alpha1/CreateWorkspace", req, &rsp); err != nil {
			die(err)
		}
		show(rsp.Data)
	case "ws-get":
		rsp := msgs.Rsp[map[string]any]{}
		q := url.Values{"Project": {project}, "ZoneId": {zone}, "WorkspaceId": {os.Args[2]}}.Encode()
		if err := cli.Get(ctx, "/workspace/v1alpha1/GetWorkspace", q, &rsp); err != nil {
			die(err)
		}
		show(rsp.Data)
	case "ws-list":
		rsp := msgs.Rsp[map[string]any]{}
		q := url.Values{"Project": {project}, "ZoneId": {zone}, "Limit": {"100"}}.Encode()
		if err := cli.Get(ctx, "/workspace/v1alpha1/ListWorkspaces", q, &rsp); err != nil {
			die(err)
		}
		show(rsp.Data)
	case "ws-delete":
		rsp := msgs.Rsp[map[string]any]{}
		if err := cli.Post(ctx, "/workspace/v1alpha1/DeleteWorkspace", map[string]string{"Project": project, "ZoneId": zone, "WorkspaceId": os.Args[2]}, &rsp); err != nil {
			die(err)
		}
		fmt.Println("deleted", os.Args[2])
	case "ws-stop":
		rsp := msgs.Rsp[map[string]any]{}
		if err := cli.Post(ctx, "/workspace/v1alpha1/StopWorkspace", map[string]string{"Project": project, "WorkspaceId": os.Args[2]}, &rsp); err != nil {
			die(err)
		}
		fmt.Println("stopped", os.Args[2])
	case "list":
		d, err := job.ListJobs(ctx, &job.ListJobsReq{Project: p(project), ZoneId: p(zone)})
		if err != nil {
			die(err)
		}
		for _, j := range d.Items {
			fmt.Printf("%s %s phase=%s created=%s\n", j.JobId, j.Name, j.Phase, j.CreationTime)
		}
	default:
		die(fmt.Errorf("unknown cmd %s", os.Args[1]))
	}
}
