---
name: dx-new
description: Run the dx new command to setup a new dioxus project v0.7. Use when starting a new project involving dioxus. 
allowed-tools: Read, Write, Bash(dx new:*)
---

# dx new Template

```bash
dx new {{project_name}} --template gh:dioxuslabs/dioxus-template --branch v0.7 --subtemplate {{subtemplate}} --option is_fullstack={{bool}} --option is_router={{bool}} --option is_tailwind={{bool}} --option is_prompt=true --option default_platform={{default_platform}} --verbose
```

## Editable Options
If options to select are not clear from current context, as user to clarify editable options.
### Subtemplate
Determines the extent of setup files created by the dx new command
- `Bare-Bones`: bare-bones project includes minimal organization with a single main.rs file and a few assets.
- `Jumpstart` : jumpstart project includes basic organization with an organized assets folder and a components folder. If you chose to develop with the router feature, you will also have a views folder.
- `Workspace` : workspace contains a member crate for each of the web, desktop and mobile platforms, a ui crate for shared components and if a full-stack application, an api crate for shared backend logic

### Is Fullstack (boolean)
Do you want to use Dioxus Fullstack? (`true` or `false`)

### Is Router (boolean)
Do you want to use Dioxus Router? (`true` or `false`)

### Is Router (boolean)
Do you want to use Dioxus Router? (`true` or `false`)

### Default Platform
Which platform do you want DX to serve by default?
- `web`
- `mobile`
- `desktop`

# Examples
## Example 1
User wants to start with a minimal web only application using tailwind for css styling
```bash
dx new cool_web --template gh:dioxuslabs/dioxus-template --branch v0.7 --subtemplate Bare-Bones --option is_fullstack=false --option is_router=true --option is_tailwind=true --option is_prompt=true --option default_platform=web --verbose
```

## Example 2
User wants to start with a detailed fullstack workspace for a multi-platform application with a mobile first primary target using custom vanilla css styling
```bash
dx new multiplaform --template gh:dioxuslabs/dioxus-template --branch v0.7 --subtemplate Workspace --option is_fullstack=true --option is_router=true --option is_tailwind=false --option is_prompt=true --option default_platform=mobile --verbose
```