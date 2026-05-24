# Unified Jac CLI helpers — host-side check/format/test without MCP round-trip.

:import:
    from os (getcwd);
    from pathlib (Path);
    from subprocess (run, CalledProcessError, PIPE);
    from os.path (exists, join, isfile);
    from os (access, X_OK, environ, pathsep);
    from typing (Optional, List, Dict, Any);

:import:
    from lib.jac.jac_types (:obj:JacDiagnostic, fingerprint_errors);

:obj:JacCommandResult:
    has
        str stdout,
        str stderr,
        str rawOutput,
        int exitCode,
        list[:obj:JacDiagnostic>] diagnostics;

:obj:JacCommandResult:
    can __init__(self, stdout:str='', stderr:str='', rawOutput:str='', exitCode:int=0, diagnostics:list=nil):
        if diagnostics is nil:
            diagnostics = [];
        self.stdout = stdout;
        self.stderr = stderr;
        self.rawOutput = rawOutput;
        self.exitCode = exitCode;
        self.diagnostics = diagnostics;

:obj:JacCheckResult:
    has
        list diagnostics,
        str rawOutput,
        int exitCode,
        ?str exitError;

:obj:JacFormatResult:
    has
        bool changed,
        str rawOutput,
        int exitCode;

:obj:JacTestResult:
    has
        bool passed,
        str rawOutput,
        int exitCode,
        list diagnostics;

:obj:JacRunResult:
    has
        str stdout,
        str stderr,
        int exitCode,
        ?str error;

# ── Parse helpers ──────────────────────────────────────────────────────

:obj:JacCli:
    can find_jac_binary ret ?str:
        candidates = ["jac", "jaclang"];
        for cmd in candidates:
            for dir in (environ.get("PATH") or "").split(pathsep):
                if not dir:
                    continue;
                p = join(dir, cmd);
                if isfile(p) and access(p, X_OK):
                    return cmd;
        return None;

    can strip_ansi(text:str) ret str:
        import re;
        return re.sub(r'\x1b\[[0-9;]*m', '', text);

    can parse_jac_check_output(stdout:str, stderr:str) ret list:
        import re;
        diagnostics = [];
        combined = stdout + "\n" + stderr;
        lines = combined.split("\n");
        pending = None;

        for raw in lines:
            stripped = self.strip_ansi(raw);
            trimmed = stripped.strip();
            if not trimmed:
                continue;

            # Single-line format: file:line:col: severity: message
            single = re.match(r'^(.+?):(\d+):(\d+):\s+(error|warning|info):\s+(.*)$', trimmed, re.I);
            if single:
                diagnostics.append(:obj:JacDiagnostic(
                    file=single.group(1),
                    line=int(single.group(2)),
                    column=int(single.group(3)),
                    severity=single.group(4).lower(),
                    message=single.group(5),
                    raw=trimmed,
                ));
                pending = None;
                continue;

            # Multi-line header: Error: message
            header = re.match(
                r'^(?:[✖✗❌]\s*)?(Error|Warning|Info|Note)(?::\s*(?:(error|warning|info)\[([A-Z0-9]+)\])?)?:?\s*(.*)$',
                trimmed, re.I
            );
            if header and re.match(r'^[✖✗❌]?\s*(Error|Warning|Info|Note)', trimmed, re.I):
                pending = {
                    'severity': (header.group(2) or header.group(1)).lower(),
                    'code': header.group(3),
                    'message': (header.group(4) or '').strip(),
                    'raw': trimmed,
                };
                continue;

            # Location: --> file:line:col
            loc = re.match(r'^-->\s*(.+?):(\d+):(\d+)\s*$', trimmed);
            if loc and pending:
                diagnostics.append(:obj:JacDiagnostic(
                    file=loc.group(1),
                    line=int(loc.group(2)),
                    column=int(loc.group(3)),
                    severity=pending['severity'],
                    code=pending.get('code'),
                    message=pending['message'],
                    raw=pending['raw'],
                ));
                pending = None;

        return diagnostics;

    can format_diagnostics(diagnostics:list) ret str:
        lines = [];
        for d in diagnostics:
            col = f":{d.column}" if d.column else "";
            code = f" [{d.code}]" if d.code else "";
            lines.append(f"- {d.file}:{d.line}{col} [{d.severity}]{code} {d.message}");
        return "\n".join(lines);

    can run_jac_command(cmd:list, cwd:str, timeout_ms:int=120_000, parse_diagnostics:bool=False) ret :obj:JacCommandResult:
        jac_bin = self.find_jac_binary();
        if not jac_bin:
            raise Exception("jac binary not found. Install with: pip install jaclang");
        if not cmd:
            raise Exception("run_jac_command requires at least one subcommand arg");

        timeout_sec = timeout_ms // 1000;
        try:
            result = run(
                [jac_bin] + cmd,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=timeout_sec,
            );
            raw_output = result.stdout + result.stderr;
            diags = self.parse_jac_check_output(result.stdout, result.stderr) if parse_diagnostics else [];
            return :obj:JacCommandResult(
                stdout=result.stdout,
                stderr=result.stderr,
                rawOutput=raw_output,
                exitCode=result.returncode,
                diagnostics=diags,
            );
        except CalledProcessError as e:
            stdout = e.stdout or "";
            stderr = e.stderr or "";
            raw_output = stdout + stderr;
            diags = self.parse_jac_check_output(stdout, stderr) if parse_diagnostics else [];
            exit_code = e.returncode if hasattr(e, 'returncode') else 1;
            return :obj:JacCommandResult(
                stdout=stdout,
                stderr=stderr,
                rawOutput=raw_output,
                exitCode=exit_code,
                diagnostics=diags,
            );
        except Exception as e:
            raise Exception(f"jac command failed: {e}");

    can run_jac_check(self, cwd:str, files:list=nil) ret dict:
        targets = files if files and len(files) > 0 else ["."];
        args = ["check"] + targets;
        result = self.run_jac_command(args, cwd, parse_diagnostics=True);
        exit_error = None;
        if len(result.diagnostics) == 0 and result.exitCode != 0:
            exit_error = result.stderr or "jac check failed";
        return {
            'diagnostics': result.diagnostics,
            'rawOutput': result.rawOutput,
            'exitCode': result.exitCode,
            'exitError': exit_error,
        };

    can run_jac_format(self, cwd:str, files:list) ret dict:
        if not files:
            return {'changed': False, 'rawOutput': '', 'exitCode': 0};
        result = self.run_jac_command(["format"] + files, cwd, parse_diagnostics=False);
        combined = result.rawOutput.strip();
        changed = "changed" in combined and "FAILURES" not in combined;
        return {'changed': changed, 'rawOutput': combined, 'exitCode': result.exitCode};

    can run_jac_test(self, cwd:str, files:list=nil) ret dict:
        args = ["test"];
        if files and len(files) > 0:
            args.extend(files);
        result = self.run_jac_command(args, cwd, timeout_ms=300_000, parse_diagnostics=True);
        errors = [d for d in result.diagnostics if d.severity == "error"];
        passed = result.exitCode == 0 and len(errors) == 0;
        return {
            'passed': passed,
            'rawOutput': result.rawOutput,
            'exitCode': result.exitCode,
            'diagnostics': result.diagnostics,
        };

    can run_jac_run(self, cwd:str, file:str, args:list=nil, timeout_ms:int=60_000) ret dict:
        cmd_args = ["run", file];
        if args:
            cmd_args.extend(args);
        try:
            result = self.run_jac_command(cmd_args, cwd, timeout_ms=timeout_ms, parse_diagnostics=False);
            error = result.stderr.strip() or "jac run failed" if result.exitCode != 0 else None;
            return {
                'stdout': result.stdout,
                'stderr': result.stderr,
                'exitCode': result.exitCode,
                'error': error,
            };
        except Exception as e:
            return {
                'stdout': '',
                'stderr': str(e),
                'exitCode': 1,
                'error': str(e),
            };
