########################################################################
# Generates XML document from SQL SELECT statement. 
# Omits xml declaration for easy xml serialization
#
# Copyright (c) 2004-2005 by Tomas Zeman <tzeman@volny.cz>
#
# Licensed under the terms of General Public License.
#
# $Id$
#
# This software is provided 'as is' with no warranty.
########################################################################

package XMLSQL;

use constant cvsID => '$Id$';
use strict;
no warnings;
use POSIX qw(strftime);
use XML::Writer;
use XML::Writer::String;
use DBI;

# Internal Status (State variables)
my $STATUS_Ok =	0;	# Ok
my $STATUS_SQL = -1;	# SQL error, with SQL query as a parameter


########################################################################
# PUBLIC Methods
########################################################################


# Constructor
#
# @param dbh database handle as returned by DBI->connect
sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = {
		dbh => 0,
		_data => '',
	};
	$self->{dbh} = shift;
	bless($self, $class);
	return ($self);
}

# Simple select query
#
# Query database with the supplied <code>sql</code> and get result as 
# collection of rows
#
# @param sql     SQL string
# @param attribs [optional] array of field names which should be 
#		 attributes of the 'row' tag, not tags themselves
# @return        STATUS_Ok or STATUS_SQL
sub select {
	my $self = shift;
	my $SQL = shift;
	my @_attribs = (@_);
	my %attribs;
	foreach (@_attribs) {
		$attribs{$_} = 1;
	}
	my $sth;
	eval {
		$sth = $self->{dbh}->prepare($SQL);
		$sth->execute();
	} || do { 
		$self->generate_XML_error($STATUS_SQL, "Error in $SQL: MySQL returned: $@"); return $STATUS_SQL; 
	};
	my $s = new XML::Writer::String;
	my $w = new XML::Writer( OUTPUT => $s );
	$self->xml_start(\$w);
	$w->dataElement('SQL',$SQL);
	my ($rows,$names,$numFields);
	eval { 
		$rows = $sth->rows(); 
		$names = $sth->{'NAME'};
		$numFields = $sth->{'NUM_OF_FIELDS'};
	} || do { 
		$self->generate_XML_error($STATUS_SQL, "Error in rows(), names() or fields(). MySQL returned: $@"); 
		return $STATUS_SQL; 
	};
	$w->startTag('result','rows' => $rows);
	eval {
		while (my $ref = $sth->fetchrow_arrayref()) {
			my (%row, %attr);
			for (my $i = 0;  $i < $numFields;  $i++) {
				my $field = $$names[$i];
				my $val = $$ref[$i];
				if (exists $attribs{$field}) {
					$attr{$field} = $val;
				} else {
					$row{$field} = $val;
				}
			}
			$w->startTag('row', %attr);
			foreach (keys %row) {
				$w->dataElement($_, $row{$_});
			}
			$w->endTag();
		}
	};
	if ($@) { 
		$self->generate_XML_error($STATUS_SQL, "Error in result fetch. MySQL returned: $@"); 
		return $STATUS_SQL; 
	}
	$w->endTag();
	$self->xml_status(\$w, $STATUS_Ok);
	$self->xml_timestamp(\$w);
	$self->xml_end(\$w);
	$w->end();
	$self->{_data} = $s->value();
	return $STATUS_Ok;
}

# Complex query with grouping/nesting functionality
#
# Query database and return result as optionally nested <group_by> structures.
#
# @param field_list array of fields (can include `*' as per SQL language)
# @param from 	    string, source tables (with joins etc.)
# @param where      array of WHERE clauses to be joined via AND directive 
# @param group	    array of fields which occur in GROUP BY clause
# @param group_par  hash; keys are field names in <code>group</code> array, 
#		    values are comma separated list of fields which are related
#		    to group fields
# @param attribs    array of fields which will be attributes of row tag
sub select2 {
	my $self = shift;
	my ($fields_ref, $from, $where_ref, $group_ref, $order_ref, $group_par_ref, $attribs_ref) = @_;

	my $SQL = " SELECT ".join(',',@{$fields_ref});
	$SQL .= " FROM $from ";
	$SQL .= " WHERE (".join(") AND (",@{$where_ref}).") " if ($#{$where_ref} >= 0);
	$SQL .= " GROUP BY ".join(',',@{$group_ref}) if ($#{$group_ref} >= 0);
	$SQL .= " ORDER BY ".join(',',@{$order_ref}) if ($#{$order_ref} >= 0);

	my(%group,%group_par,%attribs,%group_par_map);
	foreach (@{$group_ref}) { s/^\s*(\b.*\b)\s*$/$1/; undef $group{$_}; }
	foreach my $group_key (keys %{$group_par_ref}) { 
		foreach (split(',',${$group_par_ref}{$group_key})) { 
			s/^\s*(\b.*\b)\s*$/$1/;
			$group_par{$_} = undef; 
			push @{$group_par_map{$group_key}}, $_;
		} 
	}
	foreach (@{$attribs_ref}) { 
		s/^\s*(\b.*\b)\s*$/$1/; 
		$attribs{$_} = 1; 
	}

	my $sth;
	eval {
		$sth = $self->{dbh}->prepare($SQL);
		$sth->execute();
	} || do { 
		$self->generate_XML_error($STATUS_SQL, "Error in $SQL: MySQL returned: $@"); 
		return $STATUS_SQL; 
	};
	my $s = new XML::Writer::String;
	my $w = new XML::Writer( OUTPUT => $s, NEWLINES => 1);
	$self->xml_start(\$w);
	$w->dataElement('SQL',$SQL);
	my ($rows,$names,$numFields);
	eval { 
		$rows = $sth->rows(); 
		$names = $sth->{'NAME'};
		$numFields = $sth->{'NUM_OF_FIELDS'};
	} || do { 
		$self->generate_XML_error($STATUS_SQL, "Error in rows(), names() or fields(). MySQL returned: $@"); 
		return $STATUS_SQL; 
	};
	$w->startTag('result','rows' => $rows);
	my $first = 1;
	eval {
		while (my $ref = $sth->fetchrow_arrayref()) {
			my (%row, %attr, %row_group);
			for (my $i = 0;  $i < $numFields;  $i++) {
				my $field = $$names[$i];
				my $val = $$ref[$i];
				if (exists $group{$field} || exists $group_par{$field}) {
					$row_group{$field} = $val;
				} elsif (exists $attribs{$field}) {
					$attr{$field} = $val;
				} else {
					$row{$field} = $val;
				}
			}

			my $new_group = 0;
			foreach my $group_key ( @{$group_ref}) {
				if ( ($row_group{$group_key} ne $group{$group_key}) || $new_group) {
					$new_group = 1;
					unless ($first) {
						#$w->endTag(); 			#</rowset>
						$w->endTag(); 			#</group_by>
					}
				}
			}
			$new_group = 0;
			$new_group = 1 if ($first);
			foreach my $group_key ( @{$group_ref}) {
				if ( ($row_group{$group_key} ne $group{$group_key}) || $new_group) {
					$new_group = 1;
					my %gr_attr;
					$gr_attr{field} = $group_key;
					$gr_attr{$group_key} = $row_group{$group_key} 
						if exists $attribs{$group_key};
					foreach my $group_par_key (@{$group_par_map{$group_key}}) {
						$gr_attr{$group_par_key} = $row_group{$group_par_key} 
							if exists $attribs{$group_par_key};
					}
					$w->startTag('group_by',%gr_attr);	#<group_by>
					$w->dataElement($group_key,$row_group{$group_key}) 
						unless exists $attribs{$group_key};
					foreach my $group_par_key (@{$group_par_map{$group_key}}) {
						$w->dataElement($group_par_key,$row_group{$group_par_key}) 
							unless exists $attribs{$group_par_key};
					}
					$group{$group_key} = $row_group{$group_key};
				}
			}

		
			$w->startTag('row', %attr);
			foreach (keys %row) {
				$w->dataElement($_, $row{$_});
			}
			$w->endTag();

			$first = 0 if ($first);
		}
	};
	unless ($first) {
		foreach ( @{$group_ref}) {
			$w->endTag();						#</group_by>
		}
	}
	
	if ($@) { 
		$self->generate_XML_error($STATUS_SQL, "Error in result fetch. MySQL returned: $@"); 
		return $STATUS_SQL; 
	}
	$w->endTag();
	$self->xml_status(\$w, $STATUS_Ok);
	$self->xml_timestamp(\$w);
	$self->xml_end(\$w);
	$w->end();
	$self->{_data} = $s->value();
	return $STATUS_Ok;
}

# Returns generated XML document as per <code>select()</code> or
# <code>select2()</code> function
#
# @return XML document
sub value {
	my $self = shift;
	return $self->{_data};
}


########################################################################
# PRIVATE Methods
########################################################################

# Generates error status to XML document
#
# @param status     STATUS_Ok or STATUS_SQL
# @param status_str [optional] string contained in a body of <status> tag
sub generate_XML_error {
	my $self = shift;
	my $STATUS = shift;
	my $Error_param = shift if (@_);
	$Error_param = '' unless defined $Error_param;
	my $s = new XML::Writer::String;
	my $w = new XML::Writer( OUTPUT => $s );
	$self->xml_start(\$w);
	$self->xml_status(\$w,$STATUS,$Error_param);
	$self->xml_timestamp(\$w);
	$self->xml_end(\$w);
	$w->end();
	$self->{_data} = $s->value();
	return $STATUS_Ok;			# should it return Ok or STATUS of the error?
}

# Generates <status> tag to XML document
#
# @param w_ref      reference to XML::Writer instance
# @param status     STATUS_Ok or STATUS_SQL
# @param status_str [optional] string contained in a body of <status> tag
sub xml_status {
	my $self = shift;
	my $w_ref = shift;
	my $STATUS = shift;
	my $Error_param = shift if (@_);
	$Error_param = '' unless defined $Error_param;
	# only <status></status> thing
	my $status_str;
	$status_str = 'STATUS_Ok' if ($STATUS == $STATUS_Ok);
	$status_str = 'STATUS_SQL' if ($STATUS == $STATUS_SQL);
	$$w_ref->startTag('status', 'code' => $STATUS, 'codevar' => $status_str);
	$$w_ref->characters($Error_param);
	$$w_ref->endTag();
}

# Starts XML document
#
# @param w_ref      reference to XML::Writer instance
sub xml_start {
	my $self = shift;
	my $w_ref = shift;
	#$$w_ref->xmlDecl('windows-1250');
	$$w_ref->startTag('XMLSQL', 	#'application' => 'XMLSQL', 
					'version' => '1.1');
	
}

# Finish XML document
#
# @param w_ref      reference to XML::Writer instance
sub xml_end {
	my $self = shift;
	my $w_ref = shift;
	$$w_ref->endTag(); # ie. 'document' tag
}

# Generates <generated> tag
#
# @param w_ref      reference to XML::Writer instance
sub xml_timestamp {
	my $self = shift;
	my $w_ref = shift;
	my $now = time();
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($now);
	my $now_str = strftime("%F %T", localtime($now));
	$$w_ref->startTag('generated', 	'timestamp' => $now,
					'year' => ($year + 1900),
					'month' => ($mon + 1),
					'day' => $mday,
					'hour' => $hour,
					'min' => $min,
					'sec' => $sec);
	$$w_ref->characters($now_str);
	$$w_ref->endTag();
}

1;
__END__


########################################################################
# POD Documentation
########################################################################

=head1 NAME

XMLSQL - Query SQL database and get result as XML string

=head1 SYNOPSIS

  use XMLSQL;
  use DBI;

  my $dbh = DBI->connect("DBI:mysql:database=$db_name;host=$db_host",
  	$db_user, $db_pass, {RaiseError => 1});

  my $sql = new XMLSQL($dbh);

  my @field_list = ('col1', 'col2', 'col3', 'col4');
  my @where = ('col3 = "abc"', 'col4 = "def"');
  my @group_by = ('col1', 'col3');
  my @order_by = ('col1');
  my %group_par = (
	  col1 => 'col4, col5',
  );
  my %attribs = ('col5');
  

  my $ret = $sql->select2(\@field_list, 'table1 join table2 on a=b',\@where,\@group_by,\@order_by,\%group_par,\@attribs);
  # $ret < 0 -> error
  my $str = $sql->value;

=head1 DESCRIPTION

C<XMLSQL> package executes SQL query and returns XML string as a result.

Returned XML document has the following tree structure:

 XMLSQL (version=1.1)
    |
    +- SQL
    |
    +- result (rows=n)
    |    |
    |    +-- group_by (field=abc)
    |           |
    |	     +-- group_by (field=xyz)
    |	     |      .
    |	     |	    .
    |	     |	    .
    | 	     |	    |
    |	     |	    +- row
    |	     +-- group_by
    |	     
    +-- status (code=n codevar=errstr)
    |
    +-- generated (timestamp=n year=n month=n day=n min=n sec=n)
   


Parameters are in brackets, C<n> denotes positive integer value; 
C<abc>, C<xyz> string value, C<errstr> is either C<STATUS_Ok> or C<STATUS_SQL> 
with error description in C<< <status> >> body.

=head1 METHODS

=over 4

=item new($dbh)

Create a new C<XMLSQL> object. 

C<$dbh> is a database handle.

=item select()

Execute SQL query.


=item select2()

Execute SQL query.


=item value()

Return generated XML document




=over 4
