# Better Stack collector on Docker Swarm, as a stack

A [rig](https://github.com/wesleypeeters/rig) stack that runs the [Better Stack collector](https://betterstack.com/docs/logs/collector/) on a Docker Swarm cluster. It replaces upstream's `deploy-to-swarm.sh` with a declarative stack: one `docker stack deploy` sets up every node, and nodes that join later are covered automatically.

## What runs

| Service | Mode | What it does |
|---------|------|--------------|
| `collector` | global | Upstream `ghcr.io/betterstackhq/collector`: Vector for logs, host metrics, database discovery. |
| `ebpf-host` | global | A small `docker:cli` task that starts the upstream `collector-ebpf` container on its node, with the flags Swarm can't give a task (`--privileged`, `--pid host`, `--uts host`, `--network host`). It supervises the container and removes it when the task stops. See `ebpf-host.sh`. |

Both run only on nodes labelled `better-stack.collector=true` (in CI mode; see `ci.stack.yml`).

## How this differs from the official installer

Upstream: `curl -sSL .../deploy-to-swarm.sh | MANAGER_NODE=root@manager COLLECTOR_SECRET=... bash` (as of collector v1.1.49).

1. **No SSH to each node.** The script SSHes to every node as `<user>@<swarm hostname>`, using the node's Swarm hostname as the SSH target. That fails when hostnames don't resolve from the machine running the script, and it needs SSH access to every worker. Here the eBPF container is started through the node's own Docker socket by a global Swarm service. Only the manager is contacted.
2. **No automatic network attachment.** If `ATTACH_NETWORKS` is unset, the script attaches the collector to the first five overlay networks `docker network ls` returns, in whatever order that is. Which networks a privileged-adjacent container joins then depends on how your networks happen to be named. Here no extra networks are attached. You add the ones you want in a cluster overlay (see `cluster.stack.yml.example`).
3. **Pinned images.** Upstream compose files use `:latest`. Both images are pinned here by tag and digest (`1.1.49`), and so is `docker:29.4.0-cli`.
4. **eBPF is part of the stack.** Upstream runs the eBPF container per node with `docker compose -p better-stack-collector-host up -d`, outside Swarm. Swarm doesn't know about it, so `docker stack rm` doesn't remove it and new nodes don't get it. Here it's started and removed by a Swarm service, so it follows the stack.
5. **New nodes are covered.** Upstream, a node that joins later gets the collector (global service) but not the eBPF container until someone re-runs the script. Here, labelling the node is enough.
6. **No root-only assumption.** The script runs `docker` directly on every node through SSH, with no `sudo`. Hosts where only a non-root user can log in and Docker needs `sudo` can't be installed. Here nothing is run over SSH on the nodes.
7. **The secret is a Docker secret.** Upstream passes `COLLECTOR_SECRET` as a plain environment variable on the service. That puts it in `docker service inspect`, `docker inspect` on every node and anything that dumps service specs. Here it's a Docker secret. A small entrypoint wrapper exports it into the container environment, because the image only reads it from there.

## Things this stack can't fix

- **Pinning the image doesn't pin behaviour.** The images are scaffolding. On first start, `bootstrap.sh` fetches a manifest from `$BASE_URL/api/collector/manifest` and downloads the actual programs: Ruby updater/proxy scripts, supervisord config, the Vector config and healthchecks. An updater keeps pulling new versions at runtime. Two nodes running the same image digest can run different code, and you can't review what will run before it runs.
- **The collector secret goes in a query string.** `bootstrap.sh` sends it as `?collector_secret=...` on every API call. Its retry helper also `echo`s the full URL, so the secret is written to `/var/log/supervisor/bootstrap.out.log` inside the container.
- **Vector disk buffer size isn't set here.** The default is roughly 9 GB per node. The Vector config is runtime-delivered, so there's nothing in the image to override. Change it in the Better Stack UI ("Batching on disk").
- **Prometheus scraping by annotation is Kubernetes-only.** Swarm services exposing `/metrics` (Caddy, Dragonfly, ...) aren't picked up.
- **The eBPF container is privileged and sees the whole host.** That's inherent to eBPF, not to this stack. The same goes for the collector's read-only `/` mount; narrow it in an overlay if you don't need host log files.

## Deploy

1. Label the nodes:

   ```sh
   docker node update --label-add better-stack.collector=true <node>
   ```

2. Provide the secret as `COLLECTOR_SECRET`, in the shell or in a git-ignored `.env`. `dev/collector_secret` is a placeholder for local mode only.

3. Build (resolves image digests into the lockfile) and deploy in CI mode against the manager. The stack bind-mounts host paths, so rig's governance check requires the deploying GitHub user to be in `RIG_ADMINS`:

   ```sh
   export DOCKER_HOST=ssh://root@<manager>
   export CI=true CLUSTER=<cluster> GITHUB_ACTOR=<you> RIG_ADMINS=<you>
   rig build
   rig deploy
   ```

4. Restart the services you want traced, so the eBPF instrumentation attaches to fresh processes.

### Remove

```sh
rig rm
```

When each `ebpf-host` task stops, it removes its node's `better-stack-collector-host` container. `/var/lib/better-stack` stays on each node; delete it by hand if you're done.

## Upgrading

Update both image tags and digests in `stack.yml`. Get the digests with `docker buildx imagetools inspect ghcr.io/betterstackhq/collector:<version>` and the same for `collector-ebpf`. Then redeploy. `ebpf-host` sees the changed image in its spec hash and replaces the container.
