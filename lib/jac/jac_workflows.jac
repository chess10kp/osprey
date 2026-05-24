# Jackal Jac differentiator workflows — OSP, Python→Jac, idiom review, explain, init.

:import:
    from os.path (exists, join, dirname, relpath);
    from pathlib (Path);
    import re;

:obj:ExplainMode:
    has str value;
    can __init__(self, value:str='file'):
        self.value = value;

:obj:JacWorkflows:
    can resolve_package_root ret str:
        import os;
        agent_dir = os.environ.get("JACKAL_AGENT_DIR");
        if agent_dir:
            return os.path.resolve(agent_dir);
        # Walk up from this file
        here = str(Path(__file__).resolve().parent);
        for _ in range(10):
            if exists(join(here, "pi", "skills")):
                return here;
            parent = str(Path(here).parent);
            if parent == here:
                break;
            here = parent;
        return here;

    can load_skill_content(skill_dir_name:str, package_root:?str=nil) ret str:
        root = package_root or self.resolve_package_root();
        path = join(root, "pi", "skills", skill_dir_name, "SKILL.md");
        if not exists(path):
            return "";
        try:
            raw = Path(path).read_text();
            stripped = re.sub(r'^---[\s\S]*?---\s*', '', raw, count=1).strip();
            return stripped;
        except:
            return "";

    can render_prompt_template(name:str, vars:dict, package_root:?str=nil) ret str:
        root = package_root or self.resolve_package_root();
        path = join(root, "pi", "prompts", f"{name}.md");
        if not exists(path):
            raise Exception(f"Prompt template not found: pi/prompts/{name}.md");
        text = Path(path).read_text();
        for key, value in vars.items():
            text = text.replace(f"{{{{{key}}}}}", value);
        return text.strip();

    can build_osp_prompt(description:str) ret str:
        osp_skill = self.load_skill_content("osp-skill");
        return self.render_prompt_template("osp", {
            'description': description.strip(),
            'osp_skill': osp_skill or "(osp-skill unavailable — use Jac MCP list_examples/get_example/search_docs)",
        });

    can build_convert_python_prompt(python_path:str) ret str:
        return self.render_prompt_template("convert-python", {'path': python_path.strip()});

    can build_idiom_review_prompt(paths:list) ret str:
        normalized = [p.strip() for p in paths if p.strip()];
        file_list = "\n".join(f"- `{p}`" for p in normalized) if normalized else "- (scan all `.jac` files in the project)";
        return self.render_prompt_template("review-idioms", {
            'paths': ", ".join(normalized) or "(project-wide)",
            'file_list': file_list,
        });

    can build_explain_prompt(mode:str, args:str, package_root:?str=nil) ret str:
        trimmed = args.strip();
        if mode == "walker":
            return self.render_prompt_template("explain-walker", {
                'code': trimmed or "(provide walker code after the command)",
            }, package_root);
        elif mode == "error":
            parts = trimmed.split("--ctx");
            error_text = parts[0].strip() if parts else trimmed;
            ctx = parts[1].strip() if len(parts) > 1 else "";
            return self.render_prompt_template("explain-error", {
                'error': error_text or "(paste the error after the command)",
                'context': f"Additional context:\n{ctx}" if ctx else "",
            }, package_root);
        elif mode == "graph":
            return self.render_prompt_template("explain-graph", {
                'code': trimmed or "(provide Jac code after the command)",
            }, package_root);
        else:
            return self.render_prompt_template("explain", {
                'code': trimmed or "(provide Jac code after the command)",
            }, package_root);

    can build_diagram_to_model_prompt(source:str, content:str="") ret str:
        return self.render_prompt_template("diagram-to-model", {
            'source': source.strip() or "user description",
            'content': content.strip() or "(no additional content — infer from source label)",
        });
