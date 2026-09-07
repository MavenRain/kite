"""Exercise M2 native safety oracles with buildable disposable mutants."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SUITES = ("feed", "service", "volume", "taint", "manifest")
MUTANTS = (
    (
        "hidden-tolerance-bypass", "runtime/taint.ml",
        "| Hidden -> tolerate_hidden in",
        "| Hidden -> tolerate_hidden || true in",
        "taint", "hidden-starts-require-tolerance",
    ),
    (
        "existing-start-restriction-widened", "runtime/cluster.ml",
        "~some:(fun current -> List.filter (fun name -> List.mem name current) names)",
        "~some:(fun current -> List.filter (fun name -> List.mem name current || true) names)",
        "taint", "restricted-config-disjoint-intersection",
    ),
    (
        "restricted-name-check-bypass", "runtime/cluster.ml",
        "if not (List.for_all valid_name names) ||",
        "if (false && not (List.for_all valid_name names)) ||",
        "taint", "restricted-config-invalid-name-refused",
    ),
    (
        "restricted-duplicate-check-bypass", "runtime/cluster.ml",
        "List.length (List.sort_uniq String.compare names) <> List.length names",
        "false && List.length (List.sort_uniq String.compare names) <> List.length names",
        "taint", "restricted-config-duplicate-name-refused",
    ),
    (
        "feed-gap-bypass", "runtime/feed.ml",
        "| () when entry.seq <> expected -> Error (Gap {expected; actual = entry.seq})",
        "| () when entry.seq <> expected && false -> Error (Gap {expected; actual = entry.seq})",
        "feed", "gap-does-not-advance",
    ),
    (
        "doorbell-advances-cursor", "runtime/feed.ml",
        "else Ok { state with announced = max state.announced seq }",
        "else Ok { state with announced = max state.announced seq; position = max state.position seq }",
        "feed", "notifications-are-only-hints",
    ),
    (
        "historical-feed-head-forgotten", "runtime/feed.ml",
        "let observed = {state with pending_heads = Sequence.add head_seq head_epoch state.pending_heads} in",
        "let observed = {state with pending_heads = Sequence.add head_seq head_epoch Sequence.empty} in",
        "feed", "pending-head-boundaries-survive-newer-snapshots",
    ),
    (
        "head-epoch-stale-fence-removed", "runtime/feed.ml",
        "| () when head_seq < state.head_seq || head_epoch < state.head_epoch -> Error Stale_head",
        "| () when head_seq < state.head_seq -> Error Stale_head",
        "feed", "stale-head-epoch-refused",
    ),
    (
        "feed-counter-bound-doubled", "runtime/feed.ml",
        "let max_counter = 1_000_000_000",
        "let max_counter = 2_000_000_000",
        "feed", "bounded-counters",
    ),
    (
        "feed-entry-sequence-upper-bound-removed", "runtime/feed.ml",
        "| () when entry.seq <= 0 || not (valid_counter entry.seq) -> Error (Invalid_counter \"entry_sequence\")",
        "| () when entry.seq <= 0 -> Error (Invalid_counter \"entry_sequence\")",
        "feed", "bounded-counters",
    ),
    (
        "service-stale-epoch-bypass", "runtime/service.ml",
        "| () when epoch < state.current_epoch -> Error (Stale_epoch {current = state.current_epoch; actual = epoch})",
        "| () when epoch < state.current_epoch && false -> Error (Stale_epoch {current = state.current_epoch; actual = epoch})",
        "service", "stale-epoch-refused",
    ),
    (
        "service-stale-session-bypass", "runtime/service.ml",
        "if not (same_generation source prior.identity) then Error Stale_session else",
        "if not (same_generation source prior.identity) && false then Error Stale_session else",
        "service", "new-session-resets-sequence",
    ),
    (
        "service-generation-incarnation-bypass", "runtime/service.ml",
        "let same_generation (a : sender) (b : sender) = a.incarnation = b.incarnation && a.session = b.session",
        "let same_generation (a : sender) (b : sender) = a.session = b.session",
        "service", "restart-incarnation-fences-old-session",
    ),
    (
        "volume-generation-bypass", "runtime/volume.ml",
        "| () when state.generation <> write.fence.generation -> Error Stale_generation",
        "| () when state.generation <> write.fence.generation && false -> Error Stale_generation",
        "volume", "same_epoch_handoff",
    ),
    (
        "lock-grant-epoch-fence-removed", "runtime/volume.ml",
        "else if observed.epoch <> epoch then Some Stale_epoch else None in",
        "else None in",
        "volume", "lock_grant_epoch_mismatch",
    ),
    (
        "claim-receipt-pairing-bypass", "runtime/volume.ml",
        "if receipt.claim <> claim then Error Stale_callback else",
        "if receipt.claim <> claim && false then Error Stale_callback else",
        "volume", "crossed_claim_receipt_refused",
    ),
    (
        "live-node-admission-bypass", "runtime/manifest.ml",
        "then Ok plan else Error (Admit_denied No_eligible_nodes)",
        "then Ok plan else Ok plan",
        "manifest", "no-live-node-denied",
    ),
    (
        "manifest-replicas-reports-bound", "runtime/manifest.ml",
        "| Deployment value | Stateful_set value -> Some value.replicas",
        "| Deployment value | Stateful_set value -> Some value.bound",
        "manifest", "valid-replica-bound",
    ),
)


def emit(message):
    print(message, flush=True)


def run(root, args):
    return subprocess.run(args, cwd=root, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=False, timeout=120)


def build(root):
    targets = [f"test/{suite}_test.exe" for suite in SUITES]
    return run(root, ["zsh", str(root / "dev/pin-dune.sh"), "dune", "build", *targets])


def test(root, suite, case=None):
    args = [str(root / f"_build/default/test/{suite}_test.exe")]
    if case is not None:
        args.append(case)
    return run(root, args)


def copy_sources(destination):
    destination.mkdir()
    ignored = shutil.ignore_patterns("_build", "__pycache__", "*.kir", "*.kite.js")
    for name in ("lib", "surface", "runtime", "test"):
        shutil.copytree(ROOT / name, destination / name, ignore=ignored)
    for name in ("dune-project", "dune"):
        source = ROOT / name
        if source.exists():
            shutil.copy2(source, destination / name)
    (destination / "dev").mkdir()
    shutil.copy2(ROOT / "dev/pin-dune.sh", destination / "dev/pin-dune.sh")


def exercise(copy):
    emit("M2-MUTATION baseline-build targets=" + ",".join(SUITES))
    baseline = build(copy)
    if baseline.returncode != 0:
        emit("M2-MUTATION-FAIL baseline-build\n" + baseline.stdout[-8000:])
        return 1
    for suite in SUITES:
        outcome = test(copy, suite)
        if outcome.returncode != 0:
            emit(f"M2-MUTATION-FAIL baseline-tests suite={suite}\n{outcome.stdout[-8000:]}")
            return 1
        emit(outcome.stdout.strip())

    # Runtime_suite reports unknown selectors as failures. Establish that every
    # selector really runs one passing test before counting any mutant kill.
    for name, _relative, _before, _after, suite, case in MUTANTS:
        outcome = test(copy, suite, case)
        expected = f"RUNTIME suite={suite} tests=1 ok=1 fail=0"
        if outcome.returncode != 0 or expected not in outcome.stdout.splitlines():
            emit(f"M2-MUTATION-FAIL {name} baseline-selector\n{outcome.stdout[-8000:]}")
            return 1
        emit(f"M2-MUTATION-BASELINE {name} suite={suite} case={case} tests=1 ok=1")

    killed = 0
    for name, relative, before, after, suite, case in MUTANTS:
        path = copy / relative
        original = path.read_text()
        if original.count(before) != 1:
            emit(f"M2-MUTATION-FAIL {name} anchor-count={original.count(before)}")
            return 1
        emit(f"M2-MUTATION build={name}")
        path.write_text(original.replace(before, after))
        try:
            compilation = build(copy)
            if compilation.returncode != 0:
                emit(f"M2-MUTATION-FAIL {name} unbuildable\n{compilation.stdout[-8000:]}")
                return 1
            outcome = test(copy, suite, case)
        finally:
            path.write_text(original)
        expected = f"RUNTIME-FAIL {suite} {case}"
        summary = f"RUNTIME suite={suite} tests=1 ok=0 fail=1"
        if outcome.returncode != 1 or expected not in outcome.stdout.splitlines() or \
                summary not in outcome.stdout.splitlines():
            emit(f"M2-MUTATION-FAIL {name} exit={outcome.returncode}\n{outcome.stdout[-8000:]}")
            return 1
        killed += 1
        emit(f"M2-MUTATION-KILLED {name} suite={suite} case={case} build=0 test=1")
    emit(f"M2-MUTATIONS tests={len(MUTANTS)} killed={killed} survived=0 unbuildable=0")
    return 0


def main():
    try:
        with tempfile.TemporaryDirectory(prefix="kite-durable-mutants-") as scratch:
            copy = Path(scratch) / "kite"
            copy_sources(copy)
            return exercise(copy)
    except subprocess.TimeoutExpired as error:
        emit(f"M2-MUTATION-FAIL timeout seconds={error.timeout} command={error.cmd}")
        return 1
    except OSError as error:
        emit(f"M2-MUTATION-FAIL io-error {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
