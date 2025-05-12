# /etc/nixos/configuration.nix
{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    # package = pkgs.vscodium; # If using VSCodium

    profiles.default.extensions = with pkgs.vscode-extensions; [
      # Essential Vim emulation
      vscodevim.vim # 

      # Your existing extensions:
      rust-lang.rust-analyzer # Rust Analyzer
      bbenoist.nix # Nix language support
      jnoortheen.nix-ide # Another Nix IDE option
    ];

    profiles.default.userSettings = {
      # --- VIM Extension (vscodevim.vim) Settings ---
      "vim.leader" = "<space>"; # NvChad uses space as leader

      # jj for Escape in Insert Mode
      "vim.insertModeKeyBindings" = [
        { "before" = [ "j" "j" ]; "after" = [ "<Esc>" ]; }
      ];

      # Optional: jj for Escape in Visual Mode (if you ever type jj accidentally)
      # "vim.visualModeKeyBindings" = [
      #   { "before" = ["j" "j"]; "after" = ["<Esc>"]; }
      # ];

      # Enable common Vim "plugin-like" features built into vscodevim
      "vim.easymotion" = true;
      "vim.surround" = true;
      "vim.sneak" = true; # Provides f,F,t,T like functionality with more precision

      # Example NvChad-like leader keybindings (add more as needed!)
      # These map to VS Code commands. Find command IDs using F1 -> "Preferences: Open Keyboard Shortcuts (JSON)"
      # or by looking them up.
      "vim.normalModeKeyBindingsNonRecursive" = [
        # File operations
        { "before" = [ "<leader>" "f" "f" ]; "commands" = [ "workbench.action.quickOpen" ]; "comment" = "Find File (Ctrl+P)"; }
        { "before" = [ "<leader>" "f" "s" ]; "commands" = [ "workbench.action.files.save" ]; "comment" = "Save File (Ctrl+S)"; }
        { "before" = [ "<leader>" "w" "q" ]; "commands" = [ "workbench.action.closeActiveEditor" ]; "comment" = "Close current tab/editor"; }
        { "before" = [ "<leader>" "w" "d" ]; "commands" = [ "workbench.action.closeActiveEditor" ]; "comment" = "Same as wq, delete window"; }
        # Buffer/Tab navigation (VS Code uses "editors" or "tabs")
        { "before" = [ "<leader>" "b" "n" ]; "commands" = [ "workbench.action.nextEditor" ]; "comment" = "Next tab"; }
        { "before" = [ "<leader>" "b" "p" ]; "commands" = [ "workbench.action.previousEditor" ]; "comment" = "Previous tab"; }
        { "before" = [ "<leader>" "b" "d" ]; "commands" = [ "workbench.action.closeActiveEditor" ]; "comment" = "Close current tab (buffer delete)"; }
        # Terminal
        { "before" = [ "<leader>" "t" "n" ]; "commands" = [ "workbench.action.terminal.toggleTerminal" ]; "comment" = "Toggle Terminal"; }
        # Window/Split Navigation (VS Code calls them Editor Groups)
        # Note: VSCodeVim also has its own Ctrl+W sequences for this. These are alternatives.
        { "before" = [ "<leader>" "w" "h" ]; "commands" = [ "workbench.action.focusLeftGroup" ]; "comment" = "Focus left split"; }
        { "before" = [ "<leader>" "w" "l" ]; "commands" = [ "workbench.action.focusRightGroup" ]; "comment" = "Focus right split"; }
        { "before" = [ "<leader>" "w" "k" ]; "commands" = [ "workbench.action.focusAboveGroup" ]; "comment" = "Focus split above"; }
        { "before" = [ "<leader>" "w" "j" ]; "commands" = [ "workbench.action.focusBelowGroup" ]; "comment" = "Focus split below"; }
        # Explorer
        {
          "before" = [ "<leader>" "e" ];
          "commands" = [
            "workbench.action.toggleSidebarVisibility"
            "workbench.files.action.focusFilesExplorer"
          ];
          "comment" = "Toggle Explorer/Sidebar and Focus it";
        } # <-- Semicolon after the closing brace of this list element
      ];
      # --- General VS Code Settings for a more Vim-like feel ---
      "editor.lineNumbers" = "relative"; # Relative line numbers
      "editor.cursorStyle" = "line"; # Or "block"
      "editor.cursorBlinking" = "solid";
      # "editor.renderWhitespace" = "boundary"; # See only trailing whitespace

      # Make editor scrolling smoother and more Vim-like
      "editor.smoothScrolling" = false; # Vim scrolling is not smooth
      "editor.scrollBeyondLastLine" = false; # Common Vim preference
      "workbench.list.smoothScrolling" = false;

      # Optional: Hide parts of the UI for a more minimal NvChad feel
      # "workbench.activityBar.visible" = false;
      # "workbench.statusBar.visible" = false; # Careful, this hides Vim mode indicator and other useful info
      # "editor.minimap.enabled" = false;

      # --- Your existing settings ---
      "nix.formatterPath" = "${pkgs.nixd}/bin/nixd"; # Example for nix formatter
    }; # <--- Semicolon at the end of the userSettings attribute set

    # VS Code native keybindings (use if vscodevim.vim can't handle it or for non-Vim actions)
    # These are global VS Code keybindings, not Vim mode specific.
    # profiles.default.keybindings = [
    #   # Example: If you wanted Ctrl+S to *always* save, even in Vim's insert mode,
    #   # overriding any Vim behavior for Ctrl+S in insert mode.
    #   # { "key" = "ctrl+s"; "command" = "workbench.action.files.save"; "when" = "editorTextFocus"; }
    # ];
  }; # <--- Semicolon at the end of the programs.vscode attribute set

  home.packages = [
    pkgs.nil
  ];
}
