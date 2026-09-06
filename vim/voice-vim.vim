" voice-vim: buffer settings for an ephemeral dictation session.
" Sourced by bin/voice-vim-session after the user's own config.

let s:root = expand('<sfile>:p:h:h')
if has('nvim')
  execute 'set runtimepath^=' . fnameescape(s:root)
endif

setlocal filetype=markdown
setlocal wrap linebreak nolist
setlocal textwidth=0
setlocal spell spelllang=en_us
setlocal nonumber norelativenumber
setlocal noswapfile nobackup nowritebackup noundofile
setlocal bufhidden=wipe

" Pasted text arrives as one long line per paragraph; keep formatting off so
" Flow's output is not re-wrapped mid-word.
setlocal formatoptions-=t

" Submit: save and quit. Cancel: quit with a non-zero exit code.
command! -buffer Submit write | quit
command! -buffer Cancel cquit
nnoremap <buffer> <silent> ZZ :Submit<CR>
nnoremap <buffer> <silent> <C-x> :Submit<CR>
inoremap <buffer> <silent> <C-x> <Esc>:Submit<CR>
nnoremap <buffer> <silent> ZQ :Cancel<CR>

" Start a Flow hands-free dictation from inside the buffer.
command! -buffer Dictate call system('open -g wispr-flow://start-hands-free')
nnoremap <buffer> <silent> <leader>d :Dictate<CR>

" History sidebar (Neovim only). Opens on the left unless VOICE_VIM_SIDEBAR=0.
if has('nvim')
  command! -buffer History lua require('voice-vim.history').toggle()
  nnoremap <buffer> <silent> <leader>h :History<CR>
  " Quitting the dictation buffer must end the session even with the sidebar
  " open, so close the sidebar first.
  autocmd QuitPre <buffer> ++nested lua require('voice-vim.history').close()
  if $VOICE_VIM_SIDEBAR !=# '0'
    lua require('voice-vim.history').open()
  endif
endif

echo "voice-vim: dictate, edit, then ZZ or Ctrl-X to submit, ZQ to cancel"
