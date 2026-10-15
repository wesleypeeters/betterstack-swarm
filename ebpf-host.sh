#!/bin/sh
# Runs the Better Stack eBPF container on this node with the flags Swarm can't
# give a task (privileged, host pid/uts/network), keeps it running, and removes
# it when this task is stopped. Same flags as upstream's
# swarm/docker-compose.swarm-ebpf.yml.
set -eu

name=better-stack-collector-host

# Everything that should force a replacement goes into this hash.
spec="$EBPF_IMAGE|$NODE_HOSTNAME|$ENABLE_DOCKERPROBE|$EBPF_CPUS|$EBPF_MEM_RESERVATION|$EBPF_MEM_LIMIT|$EBPF_GOMEMLIMIT"
hash=$(printf %s "$spec" | sha256sum | cut -c1-16)

stop() {
	echo "stopping $name"
	docker stop -t 90 "$name" >/dev/null 2>&1 || true
	docker rm -f "$name" >/dev/null 2>&1 || true
	exit 0
}
trap stop TERM INT

current=$(docker inspect -f '{{index .Config.Labels "better-stack.spec"}}' "$name" 2>/dev/null || true)
if [ "$current" != "$hash" ]; then
	[ -n "$current" ] && echo "spec changed ($current -> $hash), replacing $name"
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker pull -q "$EBPF_IMAGE"
	docker run -d \
		--name "$name" \
		--label "better-stack.spec=$hash" \
		--restart always \
		--init \
		--stop-signal SIGTERM \
		--stop-timeout 90 \
		--privileged \
		--pid host \
		--uts host \
		--network host \
		--cpus "$EBPF_CPUS" \
		--memory-reservation "$EBPF_MEM_RESERVATION" \
		--memory "$EBPF_MEM_LIMIT" \
		--health-cmd 'if [ -x /var/lib/better-stack/ebpf/healthcheck.sh ]; then /var/lib/better-stack/ebpf/healthcheck.sh; else exit 0; fi' \
		--health-interval 30s \
		--health-timeout 5s \
		--health-start-period 60s \
		--health-retries 2 \
		-e "GOMEMLIMIT=$EBPF_GOMEMLIMIT" \
		-e "HOSTNAME=$NODE_HOSTNAME" \
		-e "ENABLE_DOCKERPROBE=$ENABLE_DOCKERPROBE" \
		-e INSTALLED_AS=swarm \
		-v /:/host:ro \
		-v /sys/kernel/tracing:/sys/kernel/tracing:rw \
		-v /sys/kernel/debug:/sys/kernel/debug:rw \
		-v /sys/kernel/security:/sys/kernel/security:ro \
		-v /sys/fs/cgroup:/sys/fs/cgroup:ro \
		-v /var/run/docker.sock:/var/run/docker.sock:ro \
		-v /var/lib/better-stack:/var/lib/better-stack \
		"$EBPF_IMAGE" >/dev/null
	echo "started $name ($hash)"
else
	echo "$name already running with spec $hash"
	docker start "$name" >/dev/null
fi

# Supervise: if the container disappears, exit non-zero so Swarm restarts this
# task, which recreates it. `sleep & wait` keeps the trap responsive.
while :; do
	sleep 30 &
	wait $! || true
	if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]; then
		state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null) || state=missing
		# --restart always handles crashes; only act if it's gone or stuck.
		case "$state" in
			restarting) ;;
			*) echo "$name is $state, exiting so Swarm recreates it"; exit 1 ;;
		esac
	fi
done
