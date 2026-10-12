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
" In Neovim both go through lua/voice-vim/flow.lua: if Flow was started with
" Ctrl-S, :Dictate or autostart and has not pasted yet, it is stopped first
" and its paste awaited (with a timeout), so the last words are not lost and
" a cancelled dictation never lands in the target. If that machinery fails,
" Submit and Cancel still run at once.
function! VoiceVimDo(action, buf) abort
  let s:acted = 1
  if a:action ==# 'cancel'
    cquit
  endif
  let l:win = bufwinid(a:buf)
  if l:win != -1
    call win_gotoid(l:win)
  elseif bufexists(a:buf)
    execute 'buffer' a:buf
  endif
  write
  quit
endfunction

function! VoiceVimFinish(action) abort
  let l:buf = bufnr('%')
  let s:acted = 0
  if has('nvim')
    try
      call luaeval('require("voice-vim.flow").finish_then(_A[1], function() vim.fn.VoiceVimDo(_A[2], _A[1]) end)', [l:buf, a:action])
      return
    catch
      echohl WarningMsg | echomsg 'voice-vim: ' . v:exception | echohl None
      " Already ran (and failed, e.g. the write): do not run it twice.
      if s:acted | return | endif
    endtry
  endif
  call VoiceVimDo(a:action, l:buf)
endfunction

command! -buffer Submit call VoiceVimFinish('submit')
command! -buffer Cancel call VoiceVimFinish('cancel')
nnoremap <buffer> <silent> ZZ :Submit<CR>
nnoremap <buffer> <silent> <C-x> :Submit<CR>
inoremap <buffer> <silent> <C-x> <Esc>:Submit<CR>
nnoremap <buffer> <silent> ZQ :Cancel<CR>
nnoremap <buffer> <silent> <C-q> :Cancel<CR>
inoremap <buffer> <silent> <C-q> <Esc>:Cancel<CR>

" Flow hands-free from inside the buffer. Neovim: Ctrl-S toggles it without
" leaving insert mode, and a paste from Flow (or Flow's own stop shortcut,
" which ends in a paste) clears the recording state. Plain Vim: :Dictate only.
if has('nvim')
  lua pcall(function() require('voice-vim.flow').attach(0) end)
  if $VOICE_VIM_AUTOSTART_FLOW ==# '1'
    lua pcall(function() require('voice-vim.flow').assume_recording() end)
  endif
  command! -buffer Dictate lua require('voice-vim.flow').start()
  nnoremap <buffer> <silent> <C-s> <Cmd>lua require('voice-vim.flow').toggle()<CR>
  inoremap <buffer> <silent> <C-s> <Cmd>lua require('voice-vim.flow').toggle()<CR>
else
  command! -buffer Dictate call system('open -g wispr-flow://start-hands-free')
endif
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

if has('nvim')
  echo "voice-vim: Ctrl-S dictate, edit, then ZZ or Ctrl-X to submit, ZQ or Ctrl-Q to cancel"
else
  echo "voice-vim: dictate, edit, then ZZ or Ctrl-X to submit, ZQ or Ctrl-Q to cancel"
endif
