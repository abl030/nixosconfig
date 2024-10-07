echo "ヽ(⌐■_■)ノ♪"
set linebreak

"nnoremap <leader>= ddkP
"nnoremap <leader>- ddp
"
"" Mapping to Uppercase current word when in insert mode
""inoremap <leader><c-u> <Esc>viwU`^a
""inoremap <leader><C-L> <Esc>viwuea
"
"" Mapping to change case when in normal mode
"nnoremap <leader><C-U> viwUe
"nnoremap <leader><C-L> viwue
"
"" Mapping for leader as per NV Chad
"let mapleader = "\<Space>"
"
"" Mapping for writing and sourcing VIMRC
"nnoremap <leader>ev :vsplit ~/vim.vim<cr>
"nnoremap <leader>sv :source ~/vim.vim<cr>
"
"iabbrev em abl030@gmail.com
"
""surrounds current word with text
":nnoremap <leader>" viw<esc>a"<esc>bi"<esc>lel
":nnoremap <leader>' viw<esc>a'<esc>bi'<esc>lel
":nnoremap <leader>( viw<esc>a)<esc>bi(<esc>lel
"
""surrounds selected text with whatever
"vnoremap <silent> <Leader>" :<C-U>normal! `<i"<Esc>`>a"<Esc>
"vnoremap <silent> <Leader>' :<C-U>normal! `<i'<Esc>`>a'<Esc>
"vnoremap <silent> <Leader>( :<C-U>normal! `<i(<Esc>`>a)<Esc>
"vnoremap <silent> <Leader>{ :<C-U>normal! `<i{<Esc>`>a}<Esc>
"
""force myself to not use things
"inoremap <esc> <nop>
"inoremap <Up> <Nop>
"inoremap <Down> <Nop>
"inoremap <Left> <Nop>
"inoremap <Right> <Nop>
"
"" Enable spell checking for Markdown files
"autocmd FileType markdown setlocal spell
"autocmd FileType markdown lua require('cmp').setup.buffer { enabled = false }
"
"" Map Ctrl + s in insert mode to save and return to insert mode
"inoremap <C-s> <C-O>:w<CR>
"
"nnoremap <leader>fx :nohlsearch<CR>
"
"" Quote a word consisting of letters from iskeyword.
"nnoremap <silent> qw :call Quote('"')<CR>
"nnoremap <silent> qs :call Quote("'")<CR>
"nnoremap <silent> wq :call UnQuote()<CR>
"function! Quote(quote)
"  normal mz
"  exe 's/\(\k*\%#\k*\)/' . a:quote . '\1' . a:quote . '/'
"  normal `zl
"endfunction
"
"function! UnQuote()
"  normal mz
"  exe 's/["' . "'" . ']\(\k*\%#\k*\)[' . "'" . '"]/\1/'
"  normal `z
"endfunction
"
" Map 'jj' to exit insert mode
inoremap jj <Esc>

" Map ';' to ':'
nnoremap ; :

"" hide deprecation warnings.
""vim.deprecate = function() end 
