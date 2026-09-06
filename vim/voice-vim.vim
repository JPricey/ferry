" voice-vim: buffer settings for an ephemeral dictation session.
" Sourced by bin/voice-vim-session after the user's own config.

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
nnoremap <buffer> <silent> ZQ :Cancel<CR>

" Start a Flow hands-free dictation from inside the buffer.
command! -buffer Dictate call system('open -g wispr-flow://start-hands-free')
nnoremap <buffer> <silent> <leader>d :Dictate<CR>

echo "voice-vim: dictate, edit, then ZZ or Ctrl-X to submit, ZQ to cancel"
