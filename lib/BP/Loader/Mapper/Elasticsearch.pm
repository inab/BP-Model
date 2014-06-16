#!/usr/bin/perl -W

use strict;
use Carp;

use BP::Model;

use Search::Elasticsearch 1.12;
use Tie::IxHash;

# Better using something agnostic than JSON::true or JSON::false inside TO_JSON
use boolean 0.32;

package BP::Loader::Mapper::Elasticsearch;

use base qw(BP::Loader::Mapper::NoSQL);

our $SECTION;

BEGIN {
	$SECTION = 'elasticsearch';
	$BP::Loader::Mapper::storage_names{$SECTION}=__PACKAGE__;
};

my @DEFAULTS = (
	['use_https' => 'false' ],
	['nodes' => [ 'localhost' ] ],
	['port' => '' ],
	['path_prefix' => '' ],
	['user' => '' ],
	['pass' => '' ],
);

my %ABSTYPE2ES = (
	BP::Model::ColumnType::STRING_TYPE	=> ['string',['index' => 'not_analyzed']],
	BP::Model::ColumnType::TEXT_TYPE	=> ['string',undef],
	BP::Model::ColumnType::INTEGER_TYPE	=> ['long',undef],
	BP::Model::ColumnType::DECIMAL_TYPE	=> ['double',undef],
	BP::Model::ColumnType::BOOLEAN_TYPE	=> ['boolean',undef],
	BP::Model::ColumnType::TIMESTAMP_TYPE	=> ['date',undef],
	BP::Model::ColumnType::DURATION_TYPE	=> ['string',['index' => 'not_analyzed']],
	#BP::Model::ColumnType::COMPOUND_TYPE	=> ['object',undef],
	# By default, compound types should be treated as 'nested'
	BP::Model::ColumnType::COMPOUND_TYPE	=> ['nested',undef],
);

# Constructor parameters:
#	model: a BP::Model instance
#	config: a Config::IniFiles instance
sub new($$) {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	
	my $model = shift;
	my $config = shift;
	
	my $self  = $class->SUPER::new($model,$config);
	bless($self,$class);
	
	if($config->SectionExists($SECTION)) {
		foreach my $param (@DEFAULTS) {
			my($key,$defval) = @{$param};
			
			if(defined($defval)) {
				$self->{$key} = $config->val($SECTION,$key,$defval);
			} elsif($config->exists($SECTION,$key)) {
				$self->{$key} = $config->val($SECTION,$key);
			} else {
				Carp::croak("ERROR: required parameter $key not found in section $SECTION");
			}
		}
		
	} else {
		Carp::croak("ERROR: Unable to read section $SECTION");
	}
	
	# Normalizing use_https
	if(exists($self->{use_https}) && defined($self->{use_https}) && $self->{use_https} eq 'true') {
		$self->{use_https} = 1;
	} else {
		delete($self->{use_https});
	}
	
	# Normalizing userinfo
	if(exists($self->{user}) && defined($self->{user}) && length($self->{user}) > 0 && exists($self->{pass}) && defined($self->{pass})) {
		$self->{userinfo} = $self->{user} . ':' . $self->{pass};
	}
	
	# Normalizing nodes
	if(exists($self->{nodes})) {
		unless(ref($self->{nodes}) eq 'ARRAY') {
			$self->{nodes} = [split(/ *, */,$self->{nodes})];
		}
	}
	
	# Finding the correspondence between collections and concepts
	# needed for type mapping in elasticsearch
	my %colcon = ();
	my %concol = ();
	foreach my $conceptDomain (@{$model->conceptDomains}) {
		next  if($self->{release} && $conceptDomain->isAbstract());
		
		foreach my $concept (@{$conceptDomain->concepts()}) {
			my $collection;
			for(my $lookconcept = $concept , $collection = undef ; !defined($collection) && defined($lookconcept) ; ) {
				if($lookconcept->goesToCollection()) {
					# If it has a destination collection, save the collection
					$collection = $lookconcept->collection();
				} elsif(defined($lookconcept->idConcept())) {
					# If it has an identifying concept, does that concept (or one ancestor idconcept) have a destination collection
					$lookconcept = $lookconcept->idConcept();
				} else {
					$lookconcept = undef;
				}
			}
			
			if(defined($collection)) {
				# Perl hack to have something 'comparable'
				my $colid = $collection+0;
				$colcon{$colid} = []  unless(exists($colcon{$colid}));
				push(@{$colcon{$colid}}, $concept);
				
				# Perl hack to have something 'comparable'
				my $conid = $concept+0;
				$concol{$conid} = []  unless(exists($concol{$conid}));
				push(@{$concol{$conid}}, $collection);
			}
		}
	}
	
	$self->{_colConcept} = \%colcon;
	$self->{_conceptCol} = \%concol;
	
	return $self;
}

# As there is the concept of sub-document, avoid nesting the correlated concepts
sub nestedCorrelatedConcepts {
	return undef;
}

# This method returns a connection to the database
# In this case, a Search::Elasticsearch instance
sub _connect() {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	my @connParams = ();
	
	foreach my $key ('use_https','port','path_prefix','userinfo') {
		if(exists($self->{$key}) && defined($self->{$key}) && length($self->{$key}) > 0) {
			push(@connParams,$key => $self->{$key});
		}
	}
	
	# Let's test the connection
	my $es = Search::Elasticsearch->new(@connParams,'nodes' => $self->{nodes});
	
	# Setting up the parameters to the JSON serializer
	$es->transport->serializer->JSON->convert_blessed;
	
	return $es;
}

# getNativeDestination parameters:
#	collection: a BP::Model::Collection instance
# It returns a native collection object, to be used by bulkInsert, for instance
sub getNativeDestination($) {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	my $collection = shift;
	
	Carp::croak("ERROR: Input parameter must be a collection")  unless(ref($collection) && $collection->isa('BP::Model::Collection'));
	
	my $db = $self->connect();
	my $coll = $db->get_collection($collection->path);
	
	return $coll;
}

sub _FillMapping($);

# _FillMapping parameters:
#	p_columnSet: an instance of BP::Model::ColumnSet
# It returns a reference to a hash defining a Elasticsearch mapping
sub _FillMapping($) {
	my($p_columnSet) = @_;
	
	my %mappingDesc = ();
	
	foreach my $column (values(%{$p_columnSet->columns()})) {
		my $columnType = $column->columnType();
		my $esType = $ABSTYPE2ES{$columnType->type()};
		
		my %typeDecl = defined($esType->[1]) ? @{$esType->[1]}: ();
		$typeDecl{'type'} = $esType->[0];
		
		# Is this a compound type?
		my $restriction = $columnType->restriction;
		if(ref($restriction) && $restriction->isa('BP::Model::CompoundType')) {
			my $p_subMapping = _FillMapping($restriction->columnSet);
			@typeDecl{keys(%{$p_subMapping})} = values(%{$p_subMapping});
		} elsif(defined($columnType->default()) && !ref($columnType->default())) {
			$typeDecl{'null_value'} = $columnType->default();
		}
		
		$mappingDesc{$column->name()} = \%typeDecl;
	}
	
	return {
		'_all' => {
			'enabled' => boolean::true
		},
		'properties' => \%mappingDesc
	};
}

# createCollection parameters:
#	collection: A BP::Model::Collection instance
# Given a BP::Model::Collection instance, it is created, along with its indexes
sub createCollection($) {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	my $collection = shift;
	
	Carp::croak("ERROR: Input parameter must be a collection")  unless(ref($collection) && $collection->isa('BP::Model::Collection'));
	
	my $es = $self->connect();
	
	my $indexName = $collection->path;
	
	# At least, let's create the index
	$es->indices->create('index' => $indexName);
	
	my $colid = $collection+0;
	if(exists($self->{_colConcept}{$colid})) {
		foreach my $concept (@{$self->{_colConcept}{$colid}}) {
			my $conceptId = $concept->id();
			
			# Build the mapping
			my $p_mappingDesc = _FillMapping($concept->columnSet());
			
			$es->indices->put_mapping(
				'index' => $indexName,
				'type' => $conceptId,
				'body' => {
					$conceptId => $p_mappingDesc
				}
			);
		}
	}
	
	return $indexName;
}

# Trimmed down version of storeNativeModel from MongoDB
# storeNativeModel parameters:
sub storeNativeModel() {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	# First, let's create the collections and their indexes
	foreach my $collection (values(%{$self->{model}->collections})) {
		$self->createCollection($collection);
	}
}

# getDestination parameters:
#	correlatedConcept: An instance of BP::Loader::CorrelatableConcept
#	isTemp: should it be a temporary destination?
# It returns a reference to a two element array, with index name and mapping type
sub getDestination($;$) {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	my $correlatedConcept = shift;
	my $isTemp = shift;
	
	Carp::croak("ERROR: getDestination needs a BP::Loader::CorrelatableConcept instance")  unless(ref($correlatedConcept) && $correlatedConcept->isa('BP::Loader::CorrelatableConcept'));
	
	my $concept = $correlatedConcept->concept;
	my $conid = $concept+0;
	my $collection = exists($self->{_conceptCol}{$conid})?$self->{_conceptCol}{$conid}:undef;
	my $indexName = $collection->path;
	my $mappingName = $concept->id();
	return [$indexName,$mappingName];
}

# bulkPrepare parameters:
#	correlatedConcept: A BP::Loader::CorrelatableConcept instance
#	entorp: The output of BP::Loader::CorrelatableConcept->readEntry
# It returns the bulkData to be used for the bulk method from Search::Elasticsearch
sub bulkPrepare($$) {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	my $correlatedConcept = shift;
	my $entorp = shift;
	
	return [ map { {'index' => $_} } @{$entorp->[0]} ];
}

# bulkInsert parameters:
#	destination: A reference to a two element array, with index name and mapping type
#	p_batch: a reference to an array of hashes which contain the values to store.
sub bulkInsert($\@) {
	my $self = shift;
	
	Carp::croak((caller(0))[3].' is an instance method!')  unless(ref($self));
	
	my $destination = shift;
	
	Carp::croak("ERROR: bulkInsert needs an array instance")  unless(ref($destination) eq 'ARRAY');
	
	my $p_batch = shift;

	my($indexName,$mappingName) = @{$destination};
	
	my $es = $self->connect();
	
	return $es->bulk(
		'index' => $indexName,
		'type' => $mappingName,
		'body' => $p_batch
	);
}

1;
