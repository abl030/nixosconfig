Avoiding NixOS/Home Manager “Drift” Noise in Flakes

Refactoring a NixOS or Home Manager configuration often triggers rebuilds even when nothing functionally changed. This “drift noise” usually comes from nondeterministic evaluation details – like module import ordering or flake source hash changes – that cause derivation hashes to differ between evaluations. Below we outline best practices used in the wild to keep configuration outputs stable across refactors, so that CI drift checks only flag meaningful changes.
1. Stabilize List Merge Ordering

Certain NixOS options (e.g. environment.systemPackages or systemd.tmpfiles.rules) are defined as lists and merged from multiple modules. If module import order changes, the resulting list order can change, causing a new derivation hash even if the set of entries is the same. Functionally this usually doesn’t matter (unless two packages provide the same file and order determines which “wins”), but it creates noise in drift detection.

Strategies to ensure deterministic ordering:

    Use mkBefore/mkAfter (mkOrder): The NixOS module system lets you attach an order priority to list definitions. By default all definitions have priority 1000; lib.mkBefore and lib.mkAfter are shorthands for mkOrder 500 and mkOrder 1500. Attaching these can ensure certain entries always come first or last regardless of import sequence. For example, to prepend a firmware blob in hardware.firmware list:

    hardware.firmware = lib.mkBefore [ myFirmware ];

    This ensures myFirmware appears before other firmware entries. In your own modules, you can assign mkOrder numbers to stabilize relative ordering of list contributions (smaller = earlier).

    Sort or normalize the list in final config: A common trick is to sort the merged list (and remove duplicates) before using it. For instance, you can collect all package entries then apply a sort function (e.g. lexicographically by package name or attribute) so the final environment.systemPackages is consistently ordered. This can be done in a late module or using an overlay. Example using lib.lists.sort to order a list by a custom comparator:

    environment.systemPackages = lib.mkForce 
      (lib.lists.sort (a: b: builtins.lessThan (toString a) (toString b))
         (lib.unique config.environment.systemPackages));

    Here we force the final list to be a unique, sorted version of itself. Pros: Eliminates hash differences from reordering. Cons: Loses any intentional ordering (e.g. if order mattered for PATH shadowing). In practice, if you don’t rely on order for functionality, this makes builds more reproducible.

    Use lib.unique / normalization functions: Removing duplicate entries or normalizing list elements can also reduce noise. For example, Home Manager and NixOS modules often use apply = lib.unique on options to avoid duplicate values. Ensuring each package appears only once can guard against accidental order variations. Similarly, trimming whitespace or consistently formatting strings in list options can avoid trivial diffs.

    Consistent module import conventions: In large configs, consider establishing a deterministic import order (e.g. alphabetical or explicit sequence). For example, some projects auto-import all modules in a directory sorted by filename (sometimes using numeric prefixes like “10-...nix”, “20-...nix” to enforce order). This way, adding a new module doesn’t reshuffle the evaluation order. Consistent import ordering leads to consistent list merge ordering.

    Stable overlay composition: Overlays (as used in flakes) are order-sensitive and can suffer nondeterminism if defined across multiple files. The flake-parts manual notes that “the module system does not guarantee sufficiently deterministic definition ordering” for overlays when imports change. The solution is to compose overlays in a single deterministic list. For instance, you might have one module gather all overlays in a fixed sequence (or use a single flake.overlays attr). This prevents fluctuations in overlay order across Nixpkgs versions or refactors. In short, keep overlay definitions centralized or explicitly ordered to avoid random reordering.

2. Minimize Flake Source Hash Churn

Another source of drift is when store paths embed the flake’s source hash. If you directly reference self or ./. in your config, any change to the flake (even unrelated files or comments) will produce a new /nix/store/…-source path. For example, one user added a reference to the flake source in /etc and found that “rebuilds [occur] anytime any file in the flake is changed, even if it’s just refactoring”. This is because inputs.self (or ./.) is a store path that hashes all tracked files in the repo. We need to avoid using the whole flake as an input for things that should only change when specific content changes.

Techniques to reduce source-related hash noise:

    Use builtins.path with filtering: Inside flakes, prefer builtins.path over plain builtins.filterSource or ./.. builtins.path allows you to specify a name and a filter for a path, producing a content-addressed store path. Crucially, it breaks the implicit dependency on the entire flake. In contrast, builtins.filterSource inside a flake still ends up depending on the flake’s initial …-source directory, yielding a double-hash that changes on any file edit. Ilke Çan (KeenSoftware) explains that in flakes Nix will copy the whole repo to a store path <hash>-source (hash covers all tracked files), then filterSource creates <hash2>-<hash>-source for the filtered subset. Because <hash2> includes the first hash, even filtering out a file doesn’t stop that file from influencing the final hash. The takeaway: “builtins.filterSource is useless inside a flake” for avoiding churn.

    With builtins.path, you can instead do:

    src = builtins.path {
      path = ./my-folder;            # or ./. for entire repo
      name = "myproj-src";
      filter = path: type: ! lib.hasSuffix ".md" path;  # example: ignore docs
    };

    This produces a store path named myproj-src whose hash depends only on the filtered contents. You control the name (preventing …-source collisions) and limit what files count toward the hash. In the above example, editing a markdown file would not change src’s hash because it’s filtered out. Using builtins.path in place of ./. thus stabilizes derivations against unrelated repo changes. (Tip: the [nix-filter library][9] provides reusable filters for common ignore patterns, so you don’t repeat boilerplate filters in every flake.)

    Isolate configuration files and assets: If using Home Manager’s xdg.configFile or home.file options with a source = ./path, be aware that ./path is evaluated relative to the flake and can pull in the whole flake source context. To avoid this, consider two approaches:

        Separate content derivations: For example, instead of xdg.configFile."myapp/config".source = ./myconfig.yml;, use builtins.path or pkgs.writeTextFile to create a fixed-output derivation for the config. E.g.:

        xdg.configFile."myapp/config".source = pkgs.writeTextFile {
          name = "myapp-config";
          text = builtins.readFile ./myconfig.yml;
        };

        Here the store path will be named myapp-config and will only change if the content of myconfig.yml changes, not when other files do. For binary assets or directories, you can use pkgs.copyToStore or builtins.path similarly to copy just that asset with a stable name. The key is to avoid referencing self (the entire flake) – instead, reference a filtered subset or embed the content.

        Sub-flake or separate input: If you have a large directory of static data or scripts, you can turn it into its own flake or use a fixed-output fetcher. For example, some teams maintain a separate Git repo (or a submodule) for large assets and include it as a flake input (inputs.assets.url = "github:myorg/assetsrepo";). Since flake inputs are content-addressed (or pinned by VCS revision), those assets won’t cause churn in your main config’s hash unless they actually change. This separation can also make CI drift checks more focused (changes in assets vs changes in config code are decoupled).

    Use unsafeDiscardStringContext for local paths (advanced): In monorepos, a pattern from the Fluid Attacks team is to break the dependency on self for subdirectories. They define a helper like projectPath that takes a subdirectory (e.g. "/my/folder") and uses builtins.unsafeDiscardStringContext on self to get a raw path, then builtins.path to add just that folder to the store. The result is that builds only depend on the NAR of /my/folder, not the entire repo. Changing a file elsewhere doesn’t alter the store path for projectPath "/my/folder". This technique, while a bit low-level, enables incremental builds in large flakes: a code change in one component only rebuilds that component’s derivation, avoiding global hash churn. (In simpler terms, using ./subdir in a flake will usually copy just that subdir to a store path named after it, but due to flake internals it might still depend on the whole repo’s hash. The projectPath trick ensures it truly stands alone. Many cases won’t need this, but it’s good to know for large projects.)

    Beware inputs.self in system configs: Some NixOS configs drop a reference to the flake in /etc for transparency (e.g. environment.etc."current-system-flake".source = inputs.self; to record the exact flake source that built the system). While useful, this makes every rebuild different, since the store path of self changes on any commit or file change. If drift detection is a priority, you might omit such references or mitigate them. One mitigation could be filtering inputs.self to only include specific files (for instance, only the flake.lock or a version file). For example, you could do:

    environment.etc."current-system-flake-lock".source = 
      builtins.path { path = ./flake.lock; name = "flake-lock"; };

    This would put just the lock file in /etc, which only changes when inputs change, not on arbitrary refactors. In general, avoid linking raw self; use a content-addressed subset as needed.

3. Separate Scripts and Assets from Config Logic

Including runtime scripts or large assets directly in your flake can cause hash changes whenever the flake’s source changes, even if the script content is unchanged. For example, if Home Manager packages a shell script from your flake (home.packages = [ ./myscript.sh ]), the store path for myscript.sh will include the flake source hash. Strategies to address this:

    Build scripts as derivations: Instead of referencing ./myscript.sh directly, use pkgs.writeShellScriptBin "myscript" (builtins.readFile ./myscript.sh). This creates a fixed-output derivation for the script binary. The derivation’s hash will track the content of the script (via the readFile), not the flake’s entire hash. If you edit an unrelated file in the repo, myscript’s output hash remains stable. This approach pins scripts’ content.

    Content-addressable sources: Use builtins.path for directories of scripts or config files, similar to above. You might even structure your flake with a top-level ./src directory for all content that should be treated as input data, and use cleanSourceWith or Filesets (lib.fileset) to include only what’s needed. The flake’s default filtering (Git-tracked files) may include too much; a custom filter can exclude files that don’t impact these assets.

    Home Manager specifics: If you use home.file or xdg.configFile options to deploy dotfiles from your flake, consider whether those dotfiles truly need to be rebuilt on every refactor. In cases where you don’t want Nix to rebuild them at all on content changes (e.g. truly mutable files), one could use mkOutOfStoreSymlink (which symlinks to an external path). But since our goal here is drift stability, a better approach is to manage such files as separate git-pinned inputs or at least filtered subsets. Some users even maintain a separate flake for dotfiles and reference it, so that their system config flake isn’t invalidated by dotfile tweaks. The trade-off is complexity vs reproducibility.

Summary: Keep “content” (config files, scripts, data) separate from “source” (Nix code). Use fixed-output derivations or filtered paths to ensure that only real content changes (not repo metadata or unrelated files) affect their hashes.
4. Meaningful Drift Detection and Comparison

Even after applying the above practices, you may still see some drift noise. It’s worth rethinking how drift is detected:

    Avoid naive whole-derivation checks: Simply comparing the entire system derivation hash before vs after can be too strict – it flags any difference, even trivial ones. As one community member noted, during a refactor they “had to do it in really small steps and check if the results end up with the same hash”. This is burdensome. Instead, consider using diff tools that focus on semantic differences:

        nix-diff: This tool compares two derivations and explains why they differ. It can pinpoint if the difference is just in the order of store references or in particular outputs. However, its output can be verbose and it “ignores semantic information” like option names. Still, it’s useful to verify if a drift is superficial (e.g. “just the order of links in /run/current-system/sw changed”) or significant.

        nvd (Nix Version Diff): A community tool that specifically reports added/removed/changed packages between two system closures. This is great for ignoring reorderings. For example, if your environment.systemPackages just got permuted, nvd would likely report no package changes, whereas the raw hash changed. Using nvd in CI can make drift checks smarter – only fail if package sets or versions changed, not if their order in the closure output changed.

        nixos-option --recursive (or serialization): One approach under discussion is to serialize the evaluated config (to JSON or XML) and diff that. By filtering out volatile attributes (or providing dummy values for things like config.system.build.toplevel which always differ), you could compare two configs in a more abstract way. This is not trivial – functions and unevaluated parts complicate it – but tools or prototypes exist (e.g. using nixos-option in recursive mode, or even custom Nix builtins to dump the used config). The idea is to see what options changed instead of raw hashes.

    Split system vs user config baselines: If you manage NixOS and Home Manager together in one flake, consider tracking their drift separately. For instance, you might build your nixosConfigurations.<host> and homeConfigurations.<user> outputs independently and compare each to its own baseline. This way, a change in the user’s home config (which produces a different derivation for the user profile) doesn’t mark the entire system as “drifted.” Home Manager tends to change more frequently (as users install apps, etc.), so isolating its differences can reduce noise. In practice, if Home Manager is integrated as a NixOS module, you can still simulate this by focusing on the /nix/store paths for system vs home profiles separately (or by structuring your flake with a separate home-manager build output). The key is to scope drift checks to relevant parts: e.g. ensure the NixOS system closure is unchanged, and separately ensure the user environment is unchanged.

    Allow some expected differences: You might decide that certain paths or files are “allowed” to differ. For example, the /etc/current-system-flake link discussed earlier will always have a new hash (by design, it records the new config). In CI, you could explicitly filter that out when comparing closures. Similarly, if the only difference between two system closures is a documentation file timestamp or a known benign version string, you might choose to ignore it. Tools like nix-diff can be scripted to ignore specific store paths or types of differences.

    Community consensus on strictness: There is ongoing discussion about how strict drift monitoring should be. Some argue that bit-for-bit reproducibility (no hash changes) is the gold standard of Nix – any difference could hide a problem. Others point out it’s impractical during active development: “observable result stays the same” is what matters. It’s often acceptable that a refactor reorders things as long as the behavior is identical. Thus, many teams focus drift checks on functional changes (packages, enabled services, etc.) rather than exact hashes. The consensus leans toward using smarter diff tools or at least acknowledging that things like list order aren’t “real” changes. You’ll have to choose a policy that fits your workflow: either enforce exact derivation equality (and invest in eliminating all noise as above), or use a looser comparison that tolerates cosmetic changes.

5. Recommendations and Real-World Patterns

Combining the above, here are concrete practices recommended by Nix maintainers and users:

    Sort and unique your package lists unless you have a reason not to. This simple step (e.g. via a final module using lib.mkForce) has virtually no downside if package order doesn’t matter to you, and it prevents surprises like the one koolean had when a harmless refactor caused a rebuild.

    Use builtins.path for any source references in flakes. As Ilke Çan showed, it fixes the filterSource double-hash issue and makes source filtering reproducible. Always give the path a deterministic name and filter out fluff (like documentation, dotfiles, etc.). This keeps evaluation hermetic. For example, a flake-based project might do:

    # In a package derivation within flake.nix
    src = builtins.path {
      path = ./src;    # only include the src/ subdir
      name = "myapp-src";
      filter = lib.fileset.excluding [ "gitignore" "README.md" ];
    };

    Then adding a new file outside src/ won’t affect this derivation’s src. Many public flakes (e.g. those building software) use this pattern to avoid spurious rebuilds when editing non-source files.

    Pin large assets externally. If you vendored a big data file or a binary in your repo, recognize that it will inflate your flake’s hash and cause churn if anything in that file’s directory changes. A better approach is to store it outside the flake (or in a .flakeignore if that existed). Since flakes don’t yet support .flakeignore, turning such assets into a fixed-output derivation is the way to go. For instance, you can do myData = pkgs.fetchurl { url = "..."; sha256 = "..."; }; and then use myData in your config. This way the derivation for myData is separate and only changes when the actual content at the URL changes.

    Use Home Manager modules carefully: If combining Home Manager with NixOS, you might be packaging dotfiles or configs via Nix. To keep those stable, apply similar ideas: use builtins.path for directories of configs, or the home-manager.lib.file.mkOutOfStoreSymlink function if you decide to manage them outside of Nix’s build system (trading reproducibility for stability in the config). In general, treat user-level configs as data inputs – isolate them so that refactoring your Nix code doesn’t cause all your dotfiles to re-symlink.

    Leverage flake-parts (if using it): Flake-parts is a framework that modularizes flake outputs using a NixOS-like module system. It won’t magically solve drift, but it encourages good structure. Notably, you can use partitions to separate concerns. For example, you could define a partition for your nixosConfigurations and another for devShells or others. This means evaluating one won’t even load modules or inputs for the other, which can prevent incidental interference. Also, be mindful of how flake-parts merges overlays or modules – follow their best practices (e.g. define flake.overlays in one place) to avoid nondeterministic ordering.

    Test refactors with nix-diff or nvd: In CI, when a pull request only reorganizes code, run nix-diff on the previous and new system closures. If it reports only differences like “order changed” or references to a new source path, you can confidently ignore those. If using nvd, verify it shows no package changes. Over time, you’ll build a sense of which changes are noise. Some teams even maintain an allow-list of acceptable differences (e.g. known timestamp or path variations) and have CI automatically greenlight those.

In summary, achieving deterministic, refactor-stable evals is possible with some effort. The Nix community has converged on using ordering controls (mkOrder), content-addressed path filtering (builtins.path), and smarter diffing to keep “drift” checks clean. By adopting these patterns – sorting merged lists, filtering out irrelevant source files, pinning or isolating content, and using targeted comparison tools – you can refactor your NixOS/Home Manager code with confidence that only real changes will trigger rebuilds.

Sources:

    NixOS Discourse – iFreilicht on how reordering environment.systemPackages can alter the store hash with no user-visible change.

    NixOS Discourse – Warnings about referencing the entire flake (self) in configs causing rebuilds on any file change.

    NixOS Discourse – Ilkecan’s explanation of flake source hashing and why builtins.filterSource doesn’t prevent hash churn inside flakes. He demonstrates using builtins.path with a filter to fix this.

    NixOS Discourse – Example from kamadorueda (Fluid Attacks) showing an advanced projectPath method to scope store paths to subdirectories only.

    NixOS Manual – Use of mkBefore/mkAfter (mkOrder) to control definition priority in list options.

    flake-parts Documentation – Note that overlay order is not deterministic across module imports, suggesting keeping overlays in a single merge order.

    NixOS Discourse – Discussion on diffing NixOS configs, mentioning tools like nix-diff and nvd for focusing on meaningful differences.

    Foodogsquared blog – Example of using mkOutOfStoreSymlink to manage dotfiles outside the Nix store for flexibility (shows alternative approach when reproducibility is traded for stability).

Citations

How relevant is the order of elements in `environment.systemPackages`? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-relevant-is-the-order-of-elements-in-environment-systempackages/30962

How relevant is the order of elements in `environment.systemPackages`? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-relevant-is-the-order-of-elements-in-environment-systempackages/30962

NixOS Manual
https://nixos.org/manual/nixos/stable/

NixOS Manual
https://nixos.org/manual/nixos/stable/
GitHub

configuration.nix
https://github.com/jjsuperpower/nix-stuff/blob/e7f35ef41f45d791ec98a269ebf7ce04753abf0a/configuration.nix#L20-L25
GitHub

default.nix
https://github.com/finix-community/finix/blob/ceaecbd3cd6684797bb7f765fe00e128d3f20bb6/modules/finit/default.nix#L120-L128

flake-parts built in - flake-parts
https://flake.parts/options/flake-parts

NixOS: config flake store path for /run/current-system - Help - NixOS Discourse
https://discourse.nixos.org/t/nixos-config-flake-store-path-for-run-current-system/24812

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

How to make `src = ./.` in a flake.nix not change a lot? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-to-make-src-in-a-flake-nix-not-change-a-lot/15129

NixOS: config flake store path for /run/current-system - Help - NixOS Discourse
https://discourse.nixos.org/t/nixos-config-flake-store-path-for-run-current-system/24812

Managing mutable files in NixOS | foodogsquared
https://www.foodogsquared.one/posts/2023-03-24-managing-mutable-files-in-nixos/

Managing mutable files in NixOS | foodogsquared
https://www.foodogsquared.one/posts/2023-03-24-managing-mutable-files-in-nixos/

Comparing module system configurations - Development - NixOS Discourse
https://discourse.nixos.org/t/comparing-module-system-configurations/59654

Comparing module system configurations - Development - NixOS Discourse
https://discourse.nixos.org/t/comparing-module-system-configurations/59654

Comparing module system configurations - Development - NixOS Discourse
https://discourse.nixos.org/t/comparing-module-system-configurations/59654

Comparing module system configurations - Development - NixOS Discourse
https://discourse.nixos.org/t/comparing-module-system-configurations/59654

Comparing module system configurations - Development - NixOS Discourse
https://discourse.nixos.org/t/comparing-module-system-configurations/59654

Comparing module system configurations - Development - NixOS Discourse
https://discourse.nixos.org/t/comparing-module-system-configurations/59654

How relevant is the order of elements in `environment.systemPackages`? - Help - NixOS Discourse
https://discourse.nixos.org/t/how-relevant-is-the-order-of-elements-in-environment-systempackages/30962

flake-parts built in - flake-parts
https://flake.parts/options/flake-parts
