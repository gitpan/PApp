# MySQL dump 8.2
#
# Host: localhost    Database: papp
#--------------------------------------------------------
# Server version	3.23.13a-alpha

#
# Current Database: papp
#

CREATE DATABASE /*!32312 IF NOT EXISTS*/ papp;

USE papp;

#
# Table structure for table 'error'
#

CREATE TABLE error (
  id mediumint(6) unsigned NOT NULL auto_increment,
  ctime timestamp(14),
  data blob DEFAULT '' NOT NULL,
  comment text DEFAULT '' NOT NULL,
  PRIMARY KEY (id)
);

#
# Table structure for table 'msgid'
#

CREATE TABLE msgid (
  nr mediumint(6) unsigned NOT NULL auto_increment,
  id blob DEFAULT '' NOT NULL,
  app varchar(30) DEFAULT '' NOT NULL,
  lang varchar(5) DEFAULT '' NOT NULL,
  context text DEFAULT '' NOT NULL,
  PRIMARY KEY (nr)
);

#
# Table structure for table 'msgstr'
#

CREATE TABLE msgstr (
  nr mediumint(6) unsigned DEFAULT '0' NOT NULL,
  lang varchar(5) DEFAULT '' NOT NULL,
  flags set('valid','fuzzy') DEFAULT '' NOT NULL,
  msg blob DEFAULT '' NOT NULL,
  UNIQUE nr (nr,lang)
);

#
# Table structure for table 'state'
#

CREATE TABLE state (
  id int(10) unsigned NOT NULL auto_increment,
  ctime timestamp(14),
  previd int(10) unsigned DEFAULT '0' NOT NULL,
  userid int(10) unsigned DEFAULT '0' NOT NULL,
  state blob DEFAULT '' NOT NULL,
  PRIMARY KEY (id),
  KEY previd (previd)
);

#
# Table structure for table 'user'
#

CREATE TABLE user (
  id int(10) unsigned NOT NULL auto_increment,
  ctime timestamp(14),
  prefs blob DEFAULT '' NOT NULL,
  user varchar(20) DEFAULT '' NOT NULL,
  pass varchar(14) DEFAULT '' NOT NULL,
  access varchar(255) DEFAULT '' NOT NULL,
  comment varchar(255) DEFAULT '' NOT NULL,
  PRIMARY KEY (id),
  KEY user (user)
);

