# graphify GDScript patch

`GDSCRIPT_PATCH.diff` teaches our local **graphify** install (`graphifyy`, PyPI)
to extract GDScript `.gd` files as **code** — classes, functions, methods,
call graphs, and `extends` inheritance — instead of treating them as plain docs.

This is a **local patch to the installed pip package**, so it is *not* part of
graphify's normal install and **a `pip install -U graphifyy` wipes it**. This
copy lives in git so the patch itself can never be lost; re-apply it after any
graphify upgrade.

## What it changes

- `detect.py` — adds `.gd` to `CODE_EXTENSIONS`.
- `extract.py` — adds a `language_loader` hook to `LanguageConfig`, a
  `_GDSCRIPT_CONFIG` + `extract_gdscript()` driven by the `gdscript` grammar from
  `tree-sitter-language-pack`, `.gd` → `_DISPATCH`, GDScript call-resolution and
  `_init` constructor handling, `extends` → `inherits` edges (with materialised
  base-class nodes), and `inherits` added to the edge-clean whitelist.

Generated against `graphifyy` **0.8.39** (Python 3.14).

## Re-apply after a graphify upgrade

```fish
# 1. locate the installed package
set PKG (python3 -c "import graphify, os; print(os.path.dirname(graphify.__file__))")

# 2. (optional) back up first
cp $PKG/detect.py  $PKG/detect.py.bak-gdscript
cp $PKG/extract.py $PKG/extract.py.bak-gdscript

# 3. apply the patch
patch -p1 -d $PKG < tools/graphify/GDSCRIPT_PATCH.diff

# 4. install the grammar dependency (Arch / PEP-668 needs --break-system-packages)
python3 -m pip install --user --break-system-packages tree-sitter-language-pack
```

If the upgrade refactored `extract.py` enough that hunks reject, the edits must
be re-derived by hand — this patch is a safety net, not a guarantee. See the
project memory note `blockfire-graphify-gdscript` for the full rationale.

## Verify it worked

```fish
python3 -c "import graphify.detect as d, graphify.extract as e; \
print('.gd code:', '.gd' in d.CODE_EXTENSIONS, '| dispatch:', e._DISPATCH.get('.gd').__name__)"
# expect: .gd code: True | dispatch: extract_gdscript
```

Then rebuild the knowledge graph with `/graphify --update`.
