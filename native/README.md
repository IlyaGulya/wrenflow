# Native desktop application

`wrenflow-gpui` is the production macOS application and owns the GPUI window
plus its thin AppKit shell. It is intentionally an isolated Cargo workspace;
shared product behavior lives in `core/wrenflow-runtime` and the root workspace
contains only the domain, core, and runtime crates.

Build and verify it through the repository tasks:

```sh
mise run check
mise run build
```
