package XMLSQL;
# generates XML doc based on the SQL SELECT statement. Omits xml declaration for easy xml serialization
# created:	2003-05-02	tz
# changed:	2003-06-24	tz
#			added generic select2 with group_by capability

use strict;
no warnings;
use POSIX qw(strftime);
use XML::Writer;
use XML::Writer::String;
use DBI;
#use Data::Dumper;

# Internal Status (State variable)
my $STATUS_Ok =	0;	# Ok
my $STATUS_SQL = -1;	# SQL error, with SQL query as a parameter

# Results available via: value() func.


# PUBLIC Methods
sub new {#dbh:object - MySQL database handle 
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

sub select {#SQL:string - SQL statement, [attribs[]:string - array of field names which should be attributes to the 'row' tag, not tags themselves]
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
	} || do { $self->generate_XML_error($STATUS_SQL, "Error in $SQL: MySQL returned: $@"); return $STATUS_SQL; };
	my $s = new XML::Writer::String;
	my $w = new XML::Writer( OUTPUT => $s );
	$self->xml_start(\$w);
	$w->dataElement('SQL',$SQL);
	my ($rows,$names,$numFields);
	eval { 
		$rows = $sth->rows(); 
		$names = $sth->{'NAME'};
		$numFields = $sth->{'NUM_OF_FIELDS'};
	} || do { $self->generate_XML_error($STATUS_SQL, "Error in rows(), names() or fields(). MySQL returned: $@"); return $STATUS_SQL; };
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
	if ($@) { $self->generate_XML_error($STATUS_SQL, "Error in result fetch. MySQL returned: $@"); return $STATUS_SQL; };
	$w->endTag();
	$self->xml_status(\$w, $STATUS_Ok);
	$self->xml_timestamp(\$w);
	$self->xml_end(\$w);
	$w->end();
	$self->{_data} = $s->value();
	return $STATUS_Ok;
}

sub select2 {
	#field_list:array - list of fields, can be ary of "*"
	#from: string - source table[s] 
	#where: array
	#group: array
	#order: array
	#group_par: hash: key = group_key, value = comma separated list of fields which should occur when <group_by> tag is constructed
	#attribs: array

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
	foreach (@{$attribs_ref}) { s/^\s*(\b.*\b)\s*$/$1/; $attribs{$_} = 1; }


	#warn Dumper(\%group,\%group_par,\%group_par_map);


	my $sth;
	eval {
		$sth = $self->{dbh}->prepare($SQL);
		$sth->execute();
	} || do { $self->generate_XML_error($STATUS_SQL, "Error in $SQL: MySQL returned: $@"); return $STATUS_SQL; };
	my $s = new XML::Writer::String;
	#my $w = new XML::Writer( OUTPUT => $s , UNSAFE=>1);
	my $w = new XML::Writer( OUTPUT => $s, NEWLINES => 1);
	$self->xml_start(\$w);
	$w->dataElement('SQL',$SQL);
	my ($rows,$names,$numFields);
	eval { 
		$rows = $sth->rows(); 
		$names = $sth->{'NAME'};
		$numFields = $sth->{'NUM_OF_FIELDS'};
	} || do { $self->generate_XML_error($STATUS_SQL, "Error in rows(), names() or fields(). MySQL returned: $@"); return $STATUS_SQL; };
	$w->startTag('result','rows' => $rows);
	my $first = 1;
	eval {
		while (my $ref = $sth->fetchrow_arrayref()) {
			my (%row, %attr, %row_group);
			for (my $i = 0;  $i < $numFields;  $i++) {
				my $field = $$names[$i];
				my $val = $$ref[$i];
				##warn "field=$field, val=$val";
				if (exists $group{$field} || exists $group_par{$field}) {
					$row_group{$field} = $val;
				} elsif (exists $attribs{$field}) {
					$attr{$field} = $val;
				} else {
					$row{$field} = $val;
				}
			}

			#warn "row_group:".Dumper(\%row_group);
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
					#warn "New group by: $group_key, first=$first";
					my %gr_attr;
					$gr_attr{field} = $group_key;
					$gr_attr{$group_key} = $row_group{$group_key} if exists $attribs{$group_key};
					foreach my $group_par_key (@{$group_par_map{$group_key}}) {
						$gr_attr{$group_par_key} = $row_group{$group_par_key} if exists $attribs{$group_par_key};
					}
					$w->startTag('group_by',%gr_attr);	#<group_by>
					$w->dataElement($group_key,$row_group{$group_key}) unless exists $attribs{$group_key};
					foreach my $group_par_key (@{$group_par_map{$group_key}}) {
						$w->dataElement($group_par_key,$row_group{$group_par_key}) unless exists $attribs{$group_par_key};
					}
					#$w->startTag('rowset');		#<rowset>
					$group{$group_key} = $row_group{$group_key};
#					foreach my $group_par_key (@{$group_par_map{$group_key}}) {
#						$group_par{$group_par_key} = $row_group{$group_par_key};
#					}
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
	
	if ($@) { $self->generate_XML_error($STATUS_SQL, "Error in result fetch. MySQL returned: $@"); return $STATUS_SQL; };
	$w->endTag();
	$self->xml_status(\$w, $STATUS_Ok);
	$self->xml_timestamp(\$w);
	$self->xml_end(\$w);
	$w->end();
	$self->{_data} = $s->value();
	return $STATUS_Ok;
}

sub value {
	my $self = shift;
	return $self->{_data};
}

sub generate_XML_error {
	my $self = shift;
	my $STATUS = shift;
	my $Error_param = shift if (@_);
	$Error_param = '' unless defined $Error_param;
	# _data := complete BCD_Operator XML doc with error description
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

sub xml_start {
	my $self = shift;
	my $w_ref = shift;
	#$$w_ref->xmlDecl('windows-1250');
	$$w_ref->startTag('XMLSQL', 	#'application' => 'XMLSQL', 
					'version' => '1.1');
	
}

sub xml_end {
	my $self = shift;
	my $w_ref = shift;
	$$w_ref->endTag(); # ie. 'document' tag
}

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
