#!/usr/bin/env python3
"""Process-local OpenCode variant selection; never write user configuration."""
import json
import os
import shutil
import subprocess
import tempfile
import sys
from pathlib import Path


def resolve(program):
    # Windows: CreateProcess/execvp do not evaluate PATHEXT (opencode.cmd from
    # npm, WinError 2); shutil.which does. If the program is missing: clear error.
    path = shutil.which(program)
    if not path:
        raise ValueError(program + " not found in PATH")
    return path


def isolated_state(model, variant):
    result = subprocess.run([resolve("opencode"), "debug", "paths"], capture_output=True,
                            text=True, timeout=30, check=True)
    paths = [line.split(maxsplit=1)[1] for line in result.stdout.splitlines()
             if line.split(maxsplit=1)[:1] == ["state"] and len(line.split(maxsplit=1)) == 2]
    if len(paths) != 1 or not Path(paths[0]).is_absolute():
        raise ValueError("OpenCode state path not uniquely determinable")
    source = Path(paths[0])
    root = Path(tempfile.mkdtemp(prefix="herd-opencode-state-"))
    target = root / "opencode"
    target.mkdir(mode=0o700)
    try:
        # Copy preferences/history, never live locks or other process metadata.
        for name in ("model.json", "kv.json", "session.json", "prompt-history.jsonl"):
            if (source / name).is_file():
                shutil.copyfile(source / name, target / name)
                (target / name).chmod(0o600)
        model_file = target / "model.json"
        data = json.loads(model_file.read_text(encoding="utf-8")) if model_file.exists() else {}
        if not isinstance(data, dict):
            raise ValueError("invalid OpenCode model state")
        variants = data.setdefault("variant", {})
        if not isinstance(variants, dict):
            raise ValueError("invalid OpenCode variant state")
        variants[model] = variant
        model_file.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        model_file.chmod(0o600)
    except Exception:
        shutil.rmtree(root)
        raise
    return root


def check(cwd, model, variant):
    if not model or "/" not in model or not all(model.split("/", 1)):
        raise ValueError("--effort requires a provider/model (via --model or MODEL_OPENCODE; optionally OPENCODE_PROVIDER for the provider)")
    if not variant or variant.startswith("-"):
        raise ValueError("--effort requires a non-empty model variant")
    # Native catalog includes configured/custom variants; no hard-coded effort list.
    result = subprocess.run([resolve("opencode"), "models", model.split("/", 1)[0], "--verbose"],
                            cwd=cwd, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError("model catalog not readable (opencode models --verbose)")
    decoder = json.JSONDecoder()
    rest = result.stdout
    while rest.strip():
        name, sep, rest = rest.lstrip().partition("\n")
        if not sep:
            break
        try:
            item, end = decoder.raw_decode(rest.lstrip())
        except ValueError:
            raise ValueError("unexpected format of opencode models --verbose")
        rest = rest.lstrip()[end:]
        if name.strip() == model:
            if not isinstance(item, dict):
                raise ValueError("invalid model entry in the OpenCode catalog")
            variants = item.get("variants")
            if variants is None:
                variants = {}
            if not isinstance(variants, dict) or not all(isinstance(v, dict) for v in variants.values()):
                raise ValueError("invalid variants structure in the OpenCode catalog")
            if variant not in variants or variants[variant].get("disabled", False):
                raise ValueError("variant not available for this model; allowed: " +
                                 ", ".join(k for k, v in variants.items() if not v.get("disabled", False)))
            return
    raise ValueError("model not found in the OpenCode catalog")


def main():
    mode, cwd, model, variant, *command = sys.argv[1:]
    if mode == "check":
        check(cwd, model, variant)
    elif mode == "run" and command:
        os.chdir(cwd)
        program = resolve(command[0])
        state = isolated_state(model, variant)
        os.environ["XDG_STATE_HOME"] = str(state)
        # exec preserves terminal/signal handling. The private state is retained
        # in the system temp directory for diagnosis, like herd run logs.
        try:
            os.execv(program, command)
        except OSError:
            shutil.rmtree(state)
            raise
    else:
        raise ValueError("invalid internal call")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        print("[herd] opencode: " + str(error), file=sys.stderr)
        sys.exit(2)
