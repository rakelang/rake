# Website deployment checklist

The `rake-lang.org` repository is a sibling of the compiler checkout and GitHub
Pages serves its `main` branch. Deployment changes public state, so run the
publish commands only after the repository owner authorizes the release.

## Before deployment

From the `rake` checkout:

```sh
nix develop --command bash -c 'dune build && bash test/run_tests.sh && bash test/full_tests.sh'
nix shell nixpkgs#tree-sitter --command bash test/parser_differential.sh
nix develop --command bash tools/check_website.sh
git diff --check
git -C ../tree-sitter-rake diff --check
git -C ../rake-lang.org diff --check
```

Review `git status --short` in all three repositories. Confirm that
`rakec --version`, the website badge, package metadata, and Tree-sitter metadata
all say `0.3.0-alpha.1`. Inspect the website at desktop and mobile widths and
check its navigation, hero image, examples, GitHub links, and install command.

## Authorized deployment

After the compiler and grammar revisions are published, commit the reviewed
website revision and push the Pages branch:

```sh
git -C ../rake-lang.org add CNAME index.html wallpaper.png
git -C ../rake-lang.org commit -m 'Publish Rake 0.3.0-alpha.1 website'
git -C ../rake-lang.org push origin main
```

## Post-deployment verification

Wait for the Pages deployment to finish, then:

1. Open `https://rake-lang.org` at desktop and mobile widths.
2. Confirm the visible badge is `0.3.0-alpha.1 ALPHA` and the deployed source
   matches the committed `index.html`.
3. Follow the GitHub link and run the displayed clone, build, version, and
   `--verify-native --target x86-avx2` commands from a clean checkout on an
   AVX2-capable host.
4. Confirm the hero image loads, all three section links land correctly, and no
   browser console or mixed-content errors appear.
5. Run `curl -fsS https://rake-lang.org/CNAME` only if the host exposes that
   file; otherwise confirm the custom domain in the repository's Pages settings.

If any check fails, fix the repository revision and deploy a new commit. Do not
edit the hosted page independently of the checked source.
