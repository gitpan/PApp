# MySQL dump 8.12
#
# Host: localhost    Database: xcms
#--------------------------------------------------------
# Server version	3.23.30-gamma

CREATE DATABASE xcms;

#
# Table structure for table 'content'
#

CREATE TABLE content (
  id int(10) unsigned NOT NULL auto_increment,
  mtime timestamp(14),
  name varchar(100) NOT NULL default '',
  style int(10) unsigned NOT NULL default '0',
  text longblob DEFAULT '' NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY name(name)
) TYPE=MyISAM;

#
# Dumping data for table 'content'
#

INSERT INTO content VALUES (1,0,'default',1,'Hallo');

#
# Table structure for table 'style'
#

CREATE TABLE style (
  id int(10) unsigned NOT NULL auto_increment,
  mtime timestamp(14),
  name varchar(100) NOT NULL default '',
  text longblob DEFAULT '' NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY name(name)
) TYPE=MyISAM;

#
# Dumping data for table 'style'
#

INSERT INTO style VALUES (1,0,'default','<!DOCTYPE xsl:stylesheet [\n   <!ENTITY nbsp \"<xsl:text>&#160;</xsl:text>\">\n]>\n<xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\">\n\n<xsl:output method=\"xhtml\" omit-xml-declaration=\'yes\' media-type=\"text/html\" encoding=\"utf-8\"/>\n\n<xsl:template xmlns:papp=\"http://www.nethype.de/xmlns/papp\" match=\"/content\">\n   <html>\n      <head>\n         <xsl:apply-templates select=\"descendant::head/node()[name != \'title\']\"/>\n         <title>\n            <xsl:variable name=\"title\" select=\"descendant::title\"/>\n            <xsl:choose>\n               <xsl:when test=\"$title\">\n                  <xsl:value-of select=\"$title\"/>\n               </xsl:when>\n               <xsl:otherwise>\n                  <xsl:value-of select=\"concat(@package, \'/\', @module)\"/>\n               </xsl:otherwise>\n            </xsl:choose>\n         </title>\n      </head>\n      <body text=\"black\" link=\"#1010C0\" vlink=\"#101080\" alink=\"red\" bgcolor=\"#e0e0e0\">\n         <xsl:apply-templates select=\"content/node()\"/>\n         <xsl:apply-templates/>\n      </body>\n   </html>\n</xsl:template>\n\n<xsl:template xmlns:papp=\"http://www.nethype.de/xmlns/papp\" match=\"papp:module\">\n   <xsl:apply-templates/>\n</xsl:template>\n\n<xsl:template match=\"html|body\">\n   <xsl:apply-templates/>\n</xsl:template>\n\n<xsl:template match=\"head|title\">\n</xsl:template>\n\n<xsl:template match=\"javascript\">\n   <script type=\"text/javascript\" language=\"javascript\">\n      <xsl:comment>\n         <xsl:text>&#10;</xsl:text>\n         <xsl:text disable-output-escaping=\"yes\"><xsl:apply-templates/></xsl:text>\n         <xsl:text>//</xsl:text>\n      </xsl:comment>\n   </script>\n</xsl:template>\n\n<xsl:template match=\"@*|node()\">\n   <xsl:copy>\n      <xsl:apply-templates select=\"@*|node()\"/>\n   </xsl:copy>\n</xsl:template>\n\n<xsl:template match=\"text()\">\n   <xsl:if test=\"not (normalize-space() = \'\')\">\n      <xsl:value-of select=\".\"/>\n   </xsl:if>\n</xsl:template>\n\n</xsl:stylesheet>\n');

