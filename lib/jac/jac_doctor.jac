# Jac environment detection — binary, version, project layout, MCP availability.

:import:
    from os.path (exists, join, relpath, splitext);
    from os (listdir, environ, getcwd);
    from pathlib (Path);
    from subprocess (run, PIPE, CalledProcessError);
    from typing (Optional, List, Dict, Any);

:import:
    from lib.jac.jac_cli (:obj:JacCli);
    from lib.config.project_config (load_project_config);

@ :data_class
:obj:JacDoctorReport:
    has
        ?str jacBinary,
        ?str jacVersion,
        bool mcpAvailable,
        str mcpDetail,
        ?str jacTomlPath,
        ?str jacTomlEntryPoint,
        ?str jackalConfigPath,
        dict projectConfig,
        list jacFiles,
        str summary;

:obj:JacDoctor:
    can find_jac_toml(cwd:str) ret ?str:
        cur = cwd;
        while True:
            cand = join(cur, "jac.toml");
            if exists(cand):
                return cand;
            parent = str(Path(cur).parent);
            if parent == cur:
                return None;
            cur = parent;

    can parse_jac_toml_entry_point(jac_toml_path:str) ret ?str:
        try:
            import re;
            content = Path(jac_toml_path).read_text();
            quoted = re.search(r'entry_point\s*=\s*["\']([^"\']+)["\']', content);
            if quoted:
                return quoted.group(1);
            bare = re.search(r'entry_point\s*=\s*(\S+)', content);
            return bare.group(1).strip('"\'') if bare else None;
        except:
            return None;

    can find_jackal_config_path(cwd:str) ret ?str:
        cur = cwd;
        while True:
            cand = join(cur, ".jackal");
            if exists(cand):
                return cand;
            parent = str(Path(cur).parent);
            if parent == cur:
                return None;
            cur = parent;

    can walk_jac_files(cwd:str) ret list:
        jac_files = [];
        skip = {"node_modules", ".git", ".jac", "__pycache__", "dist", "build", "reference"};

        def walk(dir_path:str, depth:int):
            if depth > 8 or len(jac_files) > 500:
                return;
            try:
                entries = listdir(dir_path);
            except:
                return;
            for entry in entries:
                if entry.startswith(".") and entry != ".":
                    continue;
                if entry in skip:
                    continue;
                full = join(dir_path, entry);
                try:
                    import os;
                    st = os.stat(full);
                except:
                    continue;
                if os.path.isdir(full):
                    walk(full, depth + 1);
                    continue;
                if splitext(full)[1] == ".jac":
                    jac_files.append(relpath(full, cwd).replace("\\", "/"));

        walk(cwd, 0);
        jac_files.sort();
        return jac_files;

    can probe_jac_mcp(jac_binary:str) ret dict:
        try:
            result = run(
                [jac_binary, "mcp", "--inspect"],
                capture_output=True, text=True, timeout=8,
            );
            return {'available': True, 'detail': "jac mcp: available"};
        except:
            return {'available': False, 'detail': "jac mcp: NOT available — `jac mcp` failed. Update jaclang."};

    can format_project_config(cfg:dict, config_path:?str) ret str:
        lines = [];
        lines.append(f"config: {config_path or '(no .jackal file — using defaults)'}");
        lines.append(f"  autocheck: {cfg.get('autocheck', False)}");
        lines.append(f"  autoformat: {cfg.get('autoformat', False)}");
        lines.append(f"  verbose: {cfg.get('verbose', False)}");
        lines.append(f"  plan: {cfg.get('plan', False)}");
        lines.append(f"  maxFixAttempts: {cfg.get('maxFixAttempts', 3)}");
        lines.append(f"  mermaid: {cfg.get('mermaid', False)}");
        lines.append(f"  notify: {cfg.get('notify', False)}");
        lines.append(f"  subagents: {cfg.get('subagents', False)}");
        return "\n".join(lines);

    can run_jac_doctor(self, cwd:str) ret :obj:JacDoctorReport:
        cli = :obj:JacCli();
        jac_binary = cli.find_jac_binary();
        jac_version = None;
        mcp_available = False;
        mcp_detail = "jac mcp: NOT checked (no jac binary)";

        jac_toml_path = self.find_jac_toml(cwd);
        jac_toml_entry = self.parse_jac_toml_entry_point(jac_toml_path) if jac_toml_path else None;
        jackal_config_path = self.find_jackal_config_path(cwd);
        project_config = load_project_config(cwd);
        jac_files = self.walk_jac_files(cwd);

        if jac_binary:
            import asyncio;
            try:
                ver_result = run([jac_binary, "--version"], capture_output=True, text=True, timeout=5);
                jac_version = ver_result.stdout.strip();
            except:
                jac_version = None;
            mcp_result = self.probe_jac_mcp(jac_binary);
            mcp_available = mcp_result['available'];
            mcp_detail = mcp_result['detail'];
        else:
            mcp_detail = "jac mcp: NOT checked (jac binary missing)";

        lines = [];
        if jac_binary:
            lines.append(f"jac binary: {jac_binary}");
            if jac_version:
                lines.append(f"jac version: {jac_version}");
        else:
            lines.append("jac: NOT FOUND (install with: pip install jaclang)");
        lines.append(mcp_detail);

        if jac_toml_path:
            lines.append(f"jac.toml: {relpath(jac_toml_path, cwd).replace(chr(92), '/')}");
            if jac_toml_entry:
                lines.append(f"entry_point: {jac_toml_entry}");
        else:
            lines.append("jac.toml: not found");

        lines.append("");
        lines.append(self.format_project_config(project_config, jackal_config_path));

        if jac_files:
            lines.append(f"\n.jac files found: {len(jac_files)}");
            lines.append("\n".join(f"  {f}" for f in jac_files[:20]));
            if len(jac_files) > 20:
                lines.append(f"  ... and {len(jac_files) - 20} more");
        else:
            lines.append("\nNo .jac files found in project.");

        return :obj:JacDoctorReport(
            jacBinary=jac_binary,
            jacVersion=jac_version,
            mcpAvailable=mcp_available,
            mcpDetail=mcp_detail,
            jacTomlPath=jac_toml_path,
            jacTomlEntryPoint=jac_toml_entry,
            jackalConfigPath=jackal_config_path,
            projectConfig=project_config,
            jacFiles=jac_files,
            summary="\n".join(lines),
        );
