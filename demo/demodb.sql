# MySQL dump 8.10
#
# Host: localhost    Database: demodb
#--------------------------------------------------------
# Server version	3.23.26-beta

#
# Table structure for table 'place'
#

CREATE TABLE place (
  id mediumint(8) unsigned NOT NULL auto_increment,
  name varchar(180) DEFAULT '' NOT NULL,
  PRIMARY KEY (id)
);

#
# Dumping data for table 'place'
#

INSERT INTO place VALUES (1,'Berlin');
INSERT INTO place VALUES (2,'Karlsruhe');

#
# Table structure for table 'project'
#

CREATE TABLE project (
  id mediumint(8) unsigned NOT NULL auto_increment,
  name varchar(80) DEFAULT '' NOT NULL,
  place int(10) unsigned DEFAULT '0' NOT NULL,
  budget int(11) DEFAULT '0' NOT NULL,
  description text DEFAULT '' NOT NULL,
  PRIMARY KEY (id)
);

#
# Dumping data for table 'project'
#

INSERT INTO project VALUES (1,'Projekt1',1,100,'Grosse Stadt');
INSERT INTO project VALUES (2,'Projekt2',2,9990,'Nette Stadt');
INSERT INTO project VALUES (3,'Projekt3',2,50,'Billig');

