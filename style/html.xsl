<!DOCTYPE xsl:stylesheet [
   <!ENTITY nbsp "<xsl:text>&#160;</xsl:text>">
]>
<xsl:stylesheet version="1.0"
   xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
   xmlns:papp="http://www.plan9.de/xmlns/papp"
>

<xsl:output method="xhtml" omit-xml-declaration='yes' media-type="text/html" encoding="utf-8"/>

<xsl:template match="papp:module">
   <html>
      <head>
         <xsl:value-of select="descendant::head/node()"/>
         <title>
            <!--<xsl:value-of select="string(descendant::title/node()) | concat(@package, '/', @module)"/>-->
            <xsl:value-of select="concat(@package, '/', @module)"/>
         </title>
      </head>
      <body text="black" link="#1010C0" vlink="#101080" alink="red" bgcolor="#e0e0e0">
         <xsl:apply-templates select="descendant::body@*"/>
         <xsl:apply-templates/>
      </body>
   </html>
</xsl:template>

<xsl:template match="html|body">
   <xsl:apply-templates/>
</xsl:template>

<xsl:template match="head|title"> </xsl:template>

<!-- this can be used to color table,s just use something like
     <table color-even="#c0c0c0" color-odd="#f0f0f0">...</table>
  -->
<xsl:template match="table[@color-even]">
   <xsl:copy>
      <xsl:attribute name="border">0</xsl:attribute>
      <xsl:attribute name="cellspacing">0</xsl:attribute>
      <xsl:attribute name="cellpadding">2</xsl:attribute>
      
      <xsl:variable name="color-even" select="@color-even"/>
      <xsl:variable name="color-odd"  select="@color-odd"/>
      <xsl:variable name="color-first">
         <xsl:choose>
            <xsl:when test="@color-first"><xsl:value-of select="@color-first"/></xsl:when>
            <xsl:otherwise               ><xsl:value-of select="$color-odd"  /></xsl:otherwise>
         </xsl:choose>
      </xsl:variable>

      <xsl:for-each select="child::node()">
         <xsl:variable name="pos"><xsl:value-of select='count(preceding-sibling::tr)'/></xsl:variable>
         <xsl:choose>
            <xsl:when test='name() != "tr"'>
               <xsl:copy> <xsl:apply-templates/> </xsl:copy>
            </xsl:when>
            <xsl:when test='$pos = 0'>
               <tr bgcolor="{$color-first}">
                  <xsl:apply-templates/>
               </tr>
            </xsl:when>
            <xsl:when test='$pos mod 2 = 0'>
               <tr bgcolor="{$color-odd}">
                  <xsl:apply-templates/>
               </tr>
            </xsl:when>
            <xsl:otherwise>
               <tr bgcolor="{$color-even}">
                  <xsl:apply-templates/>
               </tr>
            </xsl:otherwise>
         </xsl:choose>
      </xsl:for-each>
   </xsl:copy>
</xsl:template>

<!-- matche "leere" td elemente und 'netscape'ifiziere sie -->
<xsl:template match="td[count(*) = 0 and normalize-space() = '']
                     | th[count(*) = 0 and normalize-space() = '']">
   <xsl:copy>
      <xsl:apply-templates select="@*"/>
      <xsl:text>&nbsp;</xsl:text>
   </xsl:copy>
</xsl:template>

<!-- insert additional rules here -->

<xsl:template match="@*|node()">
   <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
   </xsl:copy>
</xsl:template>

<xsl:template match="text()">
   <xsl:if test="not (normalize-space() = '')">
      <xsl:value-of select="."/>
   </xsl:if>
</xsl:template>

</xsl:stylesheet>

