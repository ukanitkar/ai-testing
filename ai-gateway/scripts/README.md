# ai-gateway — test scripts

| Script | Invasive? | What |
|---|---|---|
| `build.sh` | no | `cargo build` / `test` / `clippy` on the workspace |
| `baseline.sh` | no | `--agents` (what this machine has) + `--recover --dry-run` |
| `integration.sh` | no (own scratch + fixture home) | the file protocol as a deployment — 17 checks |
| `integration.sh --live` | **YES — enrols against the real cloud** | the same, but the gateway genuinely enrols, so the deltas under test are its own |
| `integration.ps1` | no (own scratch + fixture profile) | the Windows peer of `integration.sh`, same checks |
| `integration.ps1 -Live` | **YES — enrols against the real cloud** | as above |
| `teardown.sh` | repairs config | `--recover`; exit 1 if anything is left unrepaired |

`integration.sh` runs both processes as a deployment: one gateway service and one
continuous simulator, up for the whole test, with events driven over time. See
[`../simulator/`](../simulator/).

```bash
./build.sh            # build + test
./baseline.sh         # what's here, and prove recovery works
./integration.sh      # the whole protocol, as a deployment
./teardown.sh         # restore config
```

Both are safe on a dev machine: every write lands under
`target/zax-it/<timestamp>/home/`, and neither passes `--allow-login` by default,
so no browser opens.

`integration.ps1` differs in one check, deliberately. Step 9 on Unix sends
SIGTERM and asserts the simulator exits and reaps the gateway. Windows has no
equivalent a sibling process can send — `CloseMainWindow` is inert against a
console child — so the PowerShell version kills the simulator and asserts the
**gateway's own parent-death watchdog** reaps the orphan instead. Same property
(no stray listener survives its parent), different mechanism.

### The two modes, and why the default is weaker

The unmodified gateway runs in both, and nothing is ever injected. But offline it
cannot reach the control plane, so it never reaches `success` and never emits a
`ConfigDelta` — the default run therefore tests the **steady state** (reconcile,
identical-rewrite suppression, agent add/remove, liveness, clean shutdown) and the
gate only in its negative direction.

`--live` closes that: it carries the issuer through, so the gateway authenticates
and enrols against the cloud named in `test-config.yaml`, and the deltas applied
are the gateway's own. One browser sign-in, shared by every agent; the credential
store makes later runs silent.

```bash
./integration.sh          # offline: steady state, no network, no browser
./integration.sh --live   # real enrolment against the configured cloud
```

### Its logs

Kept automatically **on failure**, and on `--keep-logs`; removed on a pass so runs
do not pile up. `target/zax-it/latest` symlinks the most recent kept run.

| file | what |
|---|---|
| `home/sim.log` | the simulator, for the whole run |
| `home/logs/zax.log` | **the gateway itself** — trust bundle, enrolment, reconcile |
| `home/.broker.zip`, `home/.status.zip` | the control files, gzipped JSON |

The gateway log is the one that says *why* an agent did not enrol. The control
files need decompressing:

```bash
./integration.sh --keep-logs
L=../../target/zax-it/latest
sed 's/\x1b\[[0-9;]*m//g' "$L/home/logs/zax.log"
python3 -c "import gzip,json,sys;print(json.dumps(json.loads(gzip.open(sys.argv[1]).read()),indent=2))" \
  "$L/home/.status.zip"
```

`common.sh` is sourced by each script: it resolves `$GW`
(`target/debug/zscaler-ai-gateway`), `$SIM` (`target/debug/zax-sim`), `$DOCS` and
`$ZAX_LOG`. Override either binary with `GW=/path/to/gw ./baseline.sh`.

## Testing against real agents

`integration.sh` needs no agent installed: it points `HOME` at a fixture tree, so
detection sees a fixed set wherever it runs. To test against a *real* agent
instead, install it, launch it once so it creates its config dir, then run the
simulator directly against your own home.

## What was removed, and why

`step2-mcp-pipeline.sh`, `step3-llm-proxy.sh` and `verify-llm-gateway.sh` drove
`--mcp-server` / `--llm-proxy`, which the CLI now rejects. `step4-bootstrap.sh`
ran `$BROKER` with no arguments — that used to be the bootstrap and is now
**service mode**, so the script's own description had stopped being true.

`dev_device_plane.py` mocked ai-platform so a locally-run **daemon** would hear
the `ai_broker` toggle and start the gateway. The simulator plays the daemon
directly, so nothing in gateway testing needs it. `install-test-agents.sh`
installed agent CLIs globally to give detection something to find; the fixture
tree does that hermetically instead.

`approve_agent.py` and `admin.yaml` went too: an admin tool that needed
`zax-sdk-python`'s `zax_client` on `PYTHONPATH` plus `httpx`/`pyyaml`, unlike
everything else here. Its OIDC block lives on as the `tenant.oidc` section of
[`../simulator/test-config.yaml`](../simulator/test-config.yaml), which is what
now carries a tenant's issuer, paths and claim name.

## The one prerequisite that bites

**Shut off ZCC** before testing the gateway leg. Zscaler Client Connector
TLS-intercepts the gateway host and turns a working broker into a misleading 502.
Diagnose with:

```bash
openssl s_client -connect gateway.<cloud>:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer
```

A `CN=Bad Server Certificate` issuer is the inspection layer, and no client-side
CA bundle fixes it.
