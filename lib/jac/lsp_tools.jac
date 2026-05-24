# LSP bridge — language server integration for diagnostics, hover, definition, references.

:import:
    from os.path (exists, resolve, isabs, relpath, dirname);
    from pathlib (Path);
    from subprocess (run, PIPE, CalledProcessError);
    from typing (Optional, List, Dict, Any);
    import re;

:import:
    from lib.jac.jac_cli (:obj:JacCli);

@ :data_class
:obj:LspDiagnostic:
    has
        str file,
        int line,
        ?int column,
        str severity,  # "error" | "warning" | "info" | "hint"
        str message,
        ?str code,
        ?str source;

@ :data_class
:obj:LspHoverInfo:
    has
        str file,
        int line,
        int character,
        list contents,
        ?dict range;

@ :data_class
:obj:LspLocation:
    has
        str file,
        int line,
        ?int character,
        ?int endLine,
        ?int endCharacter,
        ?str text;

:obj:LspTools:
    can parse_check_output(output:str, default_file:?str=nil) ret list:
        import re;
        diagnostics = [];
        for raw in output.split("\n"):
            stripped = re.sub(r'\x1b\[[0-9;]*m', '', raw).strip();
            if not stripped:
                continue;
            match = re.match(r'^(.+?):(\d+):(\d+):\s+(error|warning|info):\s+(.*)$', stripped, re.I);
            if match:
                diagnostics.append(:obj:LspDiagnostic(
                    file=match.group(1),
                    line=int(match.group(2)),
                    column=int(match.group(3)),
                    severity=match.group(4).lower(),
                    message=match.group(5),
                ));
        if not diagnostics and default_file:
            error_match = re.search(r'error:\s*(.+)', output, re.I);
            if error_match:
                diagnostics.append(:obj:LspDiagnostic(
                    file=default_file, line=0,
                    severity="error", message=error_match.group(1).strip(),
                ));
        return diagnostics;

    can extract_symbol(line:str, character:int) ret str:
        if not line or character < 0 or character >= len(line):
            return "";
        def is_ident(ch):
            return ch.isalnum() or ch in ('.', '_');
        start = character;
        while start > 0 and is_ident(line[start - 1]):
            start -= 1;
        end = character;
        while end < len(line) and is_ident(line[end]):
            end += 1;
        if start == end:
            return "";
        full = line[start:end];
        parts = full.split(".");
        return parts[-1] if parts else full;

    can escape_regex(s:str) ret str:
        import re;
        return re.sub(r'[.*+?^${}()|[\]\\]', r'\\$&', s);

    can search_for_declaration(cwd:str, symbol:str) ret list:
        results = [];
        try:
            result = run(
                ["grep", "-rn", "-E", rf'^(can |test )?\b{self.escape_regex(symbol)}\b',
                 "--include=*.jac", "--include=*.py", "."],
                cwd=cwd, capture_output=True, text=True, timeout=10,
            );
            for line in result.stdout.split("\n"):
                if not line:
                    continue;
                match = re.match(r'^\.\/([^:]+):(\d+):(.*)$', line);
                if match:
                    results.append(:obj:LspLocation(
                        file=match.group(1),
                        line=int(match.group(2)),
                        text=match.group(3).strip(),
                    ));
        except:
            pass;
        return results;

    can search_for_references(cwd:str, symbol:str) ret list:
        results = [];
        try:
            result = run(
                ["grep", "-rn", "-w", symbol, "--include=*.jac", "--include=*.py", "."],
                cwd=cwd, capture_output=True, text=True, timeout=10,
            );
            for line in result.stdout.split("\n"):
                if not line:
                    continue;
                match = re.match(r'^\.\/([^:]+):(\d+):(.*)$', line);
                if match:
                    results.append(:obj:LspLocation(
                        file=match.group(1),
                        line=int(match.group(2)),
                        text=match.group(3).strip(),
                    ));
        except:
            pass;
        return results;

    can get_file_diagnostics(self, cwd:str, file_path:str) ret list:
        abs_path = resolve(cwd, file_path) if not isabs(file_path) else file_path;
        if not exists(abs_path):
            return [:obj:LspDiagnostic(file=file_path, line=0, severity="error", message=f"File not found: {file_path}")];
        cli = :obj:JacCli();
        jac_bin = cli.find_jac_binary();
        if not jac_bin:
            return [:obj:LspDiagnostic(file=file_path, line=0, severity="error", message="jac binary not found")];
        try:
            rel = relpath(abs_path, cwd);
            result = run([jac_bin, "check", rel], cwd=cwd, capture_output=True, text=True, timeout=30);
            return self.parse_check_output(result.stdout + "\n" + result.stderr, file_path);
        except CalledProcessError as e:
            output = (e.stdout or "") + "\n" + (e.stderr or "");
            if output.strip():
                return self.parse_check_output(output, file_path);
            return [:obj:LspDiagnostic(file=file_path, line=0, severity="error", message=str(e))];
        except Exception as e:
            return [:obj:LspDiagnostic(file=file_path, line=0, severity="error", message=str(e))];

    can get_hover_info(self, cwd:str, file_path:str, line:int, character:int) ret :obj:LspHoverInfo:
        abs_path = resolve(cwd, file_path) if not isabs(file_path) else file_path;
        if not exists(abs_path):
            return :obj:LspHoverInfo(file=file_path, line=line, character=character, contents=[f"File not found: {file_path}"]);
        try:
            content = Path(abs_path).read_text();
            lines = content.split("\n");
            target_line = lines[line - 1] if line <= len(lines) else "";
            start_line = max(0, line - 3);
            end_line = min(len(lines), line + 2);
            context_lines = [];
            for i, l in enumerate(lines[start_line:end_line]):
                ln = start_line + i + 1;
                marker = " >" if ln == line else "  ";
                context_lines.append(f"{marker} {str(ln).rjust(4)} | {l}");
            symbol = self.extract_symbol(target_line, character) if target_line else "";
            contents = [];
            if symbol:
                contents.append(f"Symbol: {symbol}");
            contents.append(f"{file_path}:{line}:{character}");
            contents.append("");
            contents.extend(context_lines);
            return :obj:LspHoverInfo(file=file_path, line=line, character=character, contents=contents);
        except Exception as e:
            return :obj:LspHoverInfo(file=file_path, line=line, character=character, contents=[f"Error reading file: {e}"]);

    can find_definitions(self, cwd:str, file_path:str, line:int, character:int) ret list:
        abs_path = resolve(cwd, file_path) if not isabs(file_path) else file_path;
        if not exists(abs_path):
            return [];
        try:
            content = Path(abs_path).read_text();
            target_line = content.split("\n")[line - 1] if line > 0 else "";
            if not target_line:
                return [];
            symbol = self.extract_symbol(target_line, character);
            if not symbol:
                return [];
            return self.search_for_declaration(cwd, symbol);
        except:
            return [];

    can find_references(self, cwd:str, file_path:str, line:int, character:int) ret list:
        abs_path = resolve(cwd, file_path) if not isabs(file_path) else file_path;
        if not exists(abs_path):
            return [];
        try:
            content = Path(abs_path).read_text();
            target_line = content.split("\n")[line - 1] if line > 0 else "";
            if not target_line:
                return [];
            symbol = self.extract_symbol(target_line, character);
            if not symbol:
                return [];
            return self.search_for_references(cwd, symbol);
        except:
            return [];

    can format_lsp_diagnostics(diagnostics:list) ret str:
        if not diagnostics:
            return "No diagnostics.";
        lines = [];
        for d in diagnostics:
            col = f":{d.column}" if d.column else "";
            code = f" [{d.code}]" if d.code else "";
            src = f" ({d.source})" if d.source else "";
            lines.append(f"{d.file}:{d.line}{col} [{d.severity}]{code}{src} {d.message}");
        return "\n".join(lines);

    can format_hover_info(info::obj:LspHoverInfo) ret str:
        return "\n".join(info.contents);

    can format_locations(locations:list, label:str="Results") ret str:
        if not locations:
            return f"No {label.lower()} found.";
        result = [];
        for loc in locations[:20]:
            text = f": {loc.text[:97]}..." if loc.text and len(loc.text) > 100 else (f": {loc.text}" if loc.text else "");
            result.append(f"{loc.file}:{loc.line}{text}");
        return "\n".join(result);
