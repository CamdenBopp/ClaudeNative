import sys, os
root = sys.argv[1]  # package root
co = os.path.join(root, ".build/checkouts")
# (swift identifier, package dir, path within package, tag, license holder)
entries = [
    ("swift", "tree-sitter-swift", "queries/highlights.scm", "0.7.4-with-generated-files", "alex-pinkus"),
    ("python", "tree-sitter-python", "queries/highlights.scm", "v0.23.6", "Max Brunsfeld"),
    ("javascript", "tree-sitter-javascript", "queries/highlights.scm", "v0.23.1", "Max Brunsfeld"),
    ("javascriptJSX", "tree-sitter-javascript", "queries/highlights-jsx.scm", "v0.23.1", "Max Brunsfeld"),
    ("typescript", "tree-sitter-typescript", "queries/highlights.scm", "v0.23.2", "Max Brunsfeld"),
    ("json", "tree-sitter-json", "queries/highlights.scm", "v0.24.8", "Max Brunsfeld"),
    ("bash", "tree-sitter-bash", "queries/highlights.scm", "v0.25.1", "Max Brunsfeld"),
    ("markdown", "tree-sitter-markdown", "tree-sitter-markdown/queries/highlights.scm", "v0.5.3", "Matthias Deiml"),
    ("markdownInline", "tree-sitter-markdown", "tree-sitter-markdown-inline/queries/highlights.scm", "v0.5.3", "Matthias Deiml"),
    ("html", "tree-sitter-html", "queries/highlights.scm", "v0.23.2", "Max Brunsfeld"),
    ("css", "tree-sitter-css", "queries/highlights.scm", "v0.23.2", "Max Brunsfeld"),
]
out = ["// Generated from the grammar packages' highlights.scm files; do not edit by hand.",
       "// Each query is copied verbatim from the tagged release named above it (MIT license,",
       "// copyright as noted). HighlightQueryDriftTests checks these against .build/checkouts.",
       "// They are compiled in rather than loaded from the grammars' resource bundles because",
       "// Scripts/bundle.sh copies only the executable into the .app.",
       "",
       "enum HighlightQuerySource {"]
for name, pkg, path, tag, holder in entries:
    text = open(os.path.join(co, pkg, path), encoding="utf-8").read()
    assert '"""#' not in text
    out.append(f"    /// {pkg} {tag}, {path}. MIT, copyright {holder}.")
    out.append(f"    static let {name} = #\"\"\"")
    out.append(text.rstrip("\n"))
    out.append('"""#')
    out.append("")
out[-1] = "}"
out.append("")
open(os.path.join(root, "Sources/CodeHighlighting/HighlightQuerySource.swift"), "w").write("\n".join(out))
