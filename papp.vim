" Vim syntax file for the "papp" file format (_p_erl _app_lication(?))
"
" Language:	papp
" Maintainer:	Marc Lehmann <pcg@goof.com>
" Last Change:	2000-04-04
" Location:	http://www.goof.com/pcg/marc/papp.html

" You can set the "papp_include_html" variable so that html will be
" rendered as such inside phtml sections (in case you actually put html
" there - papp does not require that). Also, rendering html tends to keep
" the clutter high on the screen - mixing three languages is difficult
" enough(!). PS: it is also slow.

" pod is, btw, allowed everywhere, which is actually wrong :(

syn clear

" source is basically xml, with included html(?) and perl bits
so $VIMRUNTIME/syntax/xml.vim

if exists("papp_include_html")
   syn include @Html $VIMRUNTIME/syntax/html.vim
endif

syn include @Perl $VIMRUNTIME/syntax/perl.vim

" preprocessor commands
syn region prep matchgroup=prep start="^#\s*\(if\|elsif\)" end="$" keepend contains=@perlExpr contained
syn match prep /^#\s*\(else\|endif\|??\).*$/ contained
" translation entries
syn region gettext start=/__"/ end=/"/ contained contains=@perlInterpDQ
syn cluster Html add=gettext,prep

" add special, paired xperl, perl and phtml tags
syn region perl  matchgroup=xmlTag start="<perl>"  end="</perl>"  contains=CDATAp,@Perl keepend
syn region xperl matchgroup=xmlTag start="<xperl>" end="</xperl>" contains=CDATAp,@Perl keepend
syn region phtml matchgroup=xmlTag start="<phtml>" end="</phtml>" contains=CDATAh,@Html,ph_perl,ph_html,ph_hint keepend
syn region perlPOD start="^=[a-z]" end="^=cut" contains=@Pod,perlTodo keepend

" cdata sections
syn region CDATAp matchgroup=xmlCdataDecl start="<!\[CDATA\[" end="\]\]>" contains=@Perl              contained keepend
syn region CDATAh matchgroup=xmlCdataDecl start="<!\[CDATA\[" end="\]\]>" contains=@Html,ph_perl,ph_html,ph_hint contained keepend

syn region ph_perl matchgroup=Delimiter start="<[:?]" end="[:?]>"me=e-2 nextgroup=ph_html contains=@Perl               contained keepend
syn region ph_html matchgroup=Delimiter start=":>"    end="<[:?]"me=e-2 nextgroup=ph_perl contains=@Html               contained keepend
syn region ph_hint matchgroup=Delimiter start="?>"    end="<[:?]"me=e-2 nextgroup=ph_perl contains=@Html,@perlInterpDQ contained keepend

" synchronization is horrors!
syn sync clear
syn sync match pappSync grouphere CDATAh "</\(perl\|xperl\|phtml\|macro\|module\)>"
syn sync match pappSync grouphere CDATAh "^# *\(if\|elsif\|else\|endif\)"
syn sync match pappSync grouphere CDATAh "</\(tr\|td\|table\|hr\|h1\|h2\|h3\)>"
syn sync match pappSync grouphere NONE   "</\=\(module\|state\|macro\)>"

syn sync maxlines=300
syn sync minlines=5

if !exists("did_papp_syntax_inits")
  let did_papp_syntax_inits = 1

  hi link perl	NONE
  hi link xperl	NONE
  hi link phtml	NONE

  hi link prep	preCondit
  hi link gettext String
endif
 
let b:current_syntax = "papp"

