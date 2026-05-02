return {

	{
		"nvim-treesitter/nvim-treesitter",
		opts = {
			ensure_installed = {
				"bash",
				"yaml",
				"ssh_config",
				"rust",
				"python",
				"nix",
				"jq",
			},
		},
		config = function(_, opts)
			require("nvim-treesitter.configs").setup(opts)

			-- nvim 0.12 changed query directive/predicate handlers: match[capture_id]
			-- is now a TSNode[] (list of nodes for quantified captures), not a single
			-- TSNode. nvim-treesitter (master branch) hasn't adapted, so any handler
			-- calling :method() on match[id] crashes. The most visible symptom is
			-- render-markdown.nvim spamming `:range() (a nil value)` on every .md
			-- buffer via the markdown injections query (#set-lang-from-info-string!).
			-- See docs/wiki/dev/neovim-debugging.md and issue #226.
			-- This re-registers the six broken handlers, unwrapping the list to
			-- preserve legacy single-node semantics.
			local q = require("vim.treesitter.query")
			local function first(match, id)
				local v = match[id]
				if type(v) == "table" then
					return v[1]
				end
				return v
			end

			-- Predicate: (#nth? @capture N) — check if node is the Nth named child
			q.add_predicate("nth?", function(match, _pattern, _bufnr, pred)
				local node = first(match, pred[2])
				local n = tonumber(pred[3])
				if node and node:parent() and node:parent():named_child_count() > n then
					return node:parent():named_child(n) == node
				end
				return false
			end, { force = true, all = false })

			-- Predicate: (#is? @capture <kind>...) — locals.lua kind matcher
			q.add_predicate("is?", function(match, _pattern, bufnr, pred)
				local locals = require("nvim-treesitter.locals")
				local node = first(match, pred[2])
				local types = { unpack(pred, 3) }
				if not node then
					return true
				end
				local _, _, kind = locals.find_definition(node, bufnr)
				return vim.tbl_contains(types, kind)
			end, { force = true, all = false })

			-- Predicate: (#kind-eq? @capture <type>...) — node:type() match
			q.add_predicate("kind-eq?", function(match, _pattern, _bufnr, pred)
				local node = first(match, pred[2])
				local types = { unpack(pred, 3) }
				if not node then
					return true
				end
				return vim.tbl_contains(types, node:type())
			end, { force = true, all = false })

			-- Directive: (#set-lang-from-mimetype! @capture) — html script type → lang
			q.add_directive("set-lang-from-mimetype!", function(match, _, bufnr, pred, metadata)
				local node = first(match, pred[2])
				if not node then
					return
				end
				local html_script_type_languages = {
					["importmap"] = "json",
					["module"] = "javascript",
					["application/ecmascript"] = "javascript",
					["text/ecmascript"] = "javascript",
				}
				local type_attr_value = vim.treesitter.get_node_text(node, bufnr)
				local configured = html_script_type_languages[type_attr_value]
				if configured then
					metadata["injection.language"] = configured
				else
					local parts = vim.split(type_attr_value, "/", {})
					metadata["injection.language"] = parts[#parts]
				end
			end, { force = true, all = false })

			-- Directive: (#set-lang-from-info-string! @capture) — fenced-code lang lookup
			-- This is THE one that crashes render-markdown on every .md buffer.
			q.add_directive("set-lang-from-info-string!", function(match, _, bufnr, pred, metadata)
				local node = first(match, pred[2])
				if not node then
					return
				end
				local non_filetype_match_injection_language_aliases = {
					ex = "elixir",
					pl = "perl",
					sh = "bash",
					uxn = "uxntal",
					ts = "typescript",
				}
				local injection_alias = vim.treesitter.get_node_text(node, bufnr):lower()
				local ft_match = vim.filetype.match({ filename = "a." .. injection_alias })
				metadata["injection.language"] = ft_match
					or non_filetype_match_injection_language_aliases[injection_alias]
					or injection_alias
			end, { force = true, all = false })

			-- Directive: (#downcase! @capture) — lowercase capture text via metadata
			q.add_directive("downcase!", function(match, _, bufnr, pred, metadata)
				local id = pred[2]
				local node = first(match, id)
				if not node then
					return
				end
				local text = vim.treesitter.get_node_text(node, bufnr, { metadata = metadata[id] }) or ""
				if not metadata[id] then
					metadata[id] = {}
				end
				metadata[id].text = string.lower(text)
			end, { force = true, all = false })
		end,
	},
}
