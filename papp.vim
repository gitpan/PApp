" Vim syntax file for the "papp" file format (_p_erl _app_lication)
"
" Language:	papp
" Maintainer:	Marc Lehmann <pcg@goof.com>
" Last Change:	2001 May 10
" Filenames:    *.papp *.pxml *.pxsl
" URL:		http://papp.plan9.de/

" You can set the "papp_include_html" variable so that html will be
" rendered as such inside phtml sections (in case you actually put html
" there - papp does not require that). Also, rendering html tends to keep
" the clutter high on the screen - mixing three languages is difficult
" enough(!). PS: it is also slow.

" pod is, btw, allowed everywhere, which is actually wrong :(

" For version 5.x: Clear all syntax items
" For version 6.x: Quit when a syntax file was already loaded
if version < 600
  syntax clear
elseif exists("b:current_syntax")
  finish
endif
let s:papp_cpo_save = &cpo
set cpo&vim

" source is basically xml, with included html (this is common) and perl bits
if version < 600
  syn include @PAppPerl <sfile>:p:h/perl.vim
else
  syn include @PAppPerl syntax/perl.vim
endif
unlet b:current_syntax

if version < 600
  so <sfile>:p:h/xml.vim
else
  runtime! syntax/xml.vim
endif
unlet b:current_syntax

if v:version >= 600
   syn cluster xmlRegionHook add=papp_perl,papp_xperl,papp_phtml,papp_pxml,papp_perlPOD
endif

" translation entries
syn region papp_gettext start=/__"/ end=/"/ contained contains=@papp_perlInterpDQ
syn cluster PAppHtml add=papp_gettext,papp_prep

" add special, paired xperl, perl and phtml tags
syn region papp_perl  matchgroup=xmlTag start="<perl>"  end="</perl>"  contains=papp_CDATAp,@PAppPerl keepend fold extend
syn region papp_xperl matchgroup=xmlTag start="<xperl>" end="</xperl>" contains=papp_CDATAp,@PAppPerl keepend fold extend
syn region papp_phtml matchgroup=xmlTag start="<phtml>" end="</phtml>" contains=papp_CDATAh,papp_ph_perl,papp_ph_html,papp_ph_hint,@PAppHtml keepend fold extend
syn region papp_pxml  matchgroup=xmlTag start="<pxml>"  end="</pxml>"  contains=papp_CDATAx,papp_ph_perl,papp_ph_xml,papp_ph_xint            keepend fold extend
syn region papp_perlPOD start="^=[a-z]" end="^=cut" contains=@Pod,perlTodo keepend

" cdata sections
syn region papp_CDATAp matchgroup=xmlCdataStart start="<!\[CDATA\[" end="\]\]>" contains=@PAppPerl,papp_prep                              contained keepend extend
syn region papp_CDATAh matchgroup=xmlCdataStart start="<!\[CDATA\[" end="\]\]>" contains=papp_prep,papp_ph_perl,papp_ph_html,papp_ph_hint,@PAppHtml contained keepend extend
syn region papp_CDATAx matchgroup=xmlCdataStart start="<!\[CDATA\[" end="\]\]>" contains=papp_prep,papp_ph_perl,papp_ph_xml,papp_ph_xint            contained keepend extend

syn region papp_ph_perl matchgroup=Delimiter start="<[:?]" end="[:?]>"me=e-2 nextgroup=papp_ph_html contains=@PAppPerl               contained keepend
syn region papp_ph_html matchgroup=Delimiter start=":>"    end="<[:?]"me=e-2 nextgroup=papp_ph_perl contains=@PAppHtml               contained keepend
syn region papp_ph_hint matchgroup=Delimiter start="?>"    end="<[:?]"me=e-2 nextgroup=papp_ph_perl contains=@perlInterpDQ,@PAppHtml contained keepend
syn region papp_ph_xml  matchgroup=Delimiter start=":>"    end="<[:?]"me=e-2 nextgroup=papp_ph_perl contains=                        contained keepend
syn region papp_ph_xint matchgroup=Delimiter start="?>"    end="<[:?]"me=e-2 nextgroup=papp_ph_perl contains=@perlInterpDQ           contained keepend

" preprocessor commands
syn region papp_prep matchgroup=papp_prep start="^#\s*\(if\|elsif\)" end="$" keepend contains=@perlExpr contained nextgroup=papp_ph_html
syn match papp_prep /^#\s*\(else\|endif\|??\).*$/ contained

" synchronization is horrors!
syn sync clear
syn sync match pappSync grouphere papp_CDATAh "</\(perl\|xperl\|phtml\|macro\|module\)>"
syn sync match pappSync grouphere papp_CDATAh "^# *\(if\|elsif\|else\|endif\)"
syn sync match pappSync grouphere papp_CDATAh "</\(tr\|td\|table\|hr\|h1\|h2\|h3\)>"
syn sync match pappSync grouphere NONE        "</\=\(module\|state\|macro\)>"

syn sync maxlines=300
syn sync minlines=50

" The default highlighting.

hi def link papp_prep		preCondit
hi def link papp_gettext	String

" The special highlighting of PApp core functions only in papp_ph_perl section

if v:version >= 600
  syn keyword pappCore surl slink sform cform suburl sublink retlink_p returl retlink
        \ current_locals reference_url multipart_form parse_multipart_form
        \ endform redirect internal_redirect abort_to content_type
        \ abort_with setlocale
        \ SURL_PUSH SURL_UNSHIFT SURL_POP SURL_SHIFT
        \ SURL_EXEC SURL_SAVE_PREFS SURL_SET_LOCALE SURL_SUFFIX
        \ surl_style
        \ SURL_STYLE_URL SURL_STYLE_GET SURL_STYLE_STATIC
        \ reload_p switch_userid save_prefs getuid
        \ dprintf dprint echo capture
        \ language_selector preferences_url preferences_link
        \ config_eval abort_with_file
        \
        \ ef_mbegin ef_sbegin ef_cbegin ef_begin ef_end
        \ ef_edit ef_may_edit ef_submit ef_reset ef_field
        \ ef_string ef_password ef_text ef_checkbox ef_radio
        \ ef_button ef_hidden ef_selectbox ef_relation
        \ ef_set ef_enum ef_file ef_constant ef_cb_begin
        \ 
        \ loginbox adminbox check_login force_login
        \ 
        \ plain_header access_page plain_footer
        \
	\ containedin=papp_ph_perl

  hi def link pappCore	 	Special
endif


let b:current_syntax = "papp"

let &cpo = s:papp_cpo_save
unlet s:papp_cpo_save


