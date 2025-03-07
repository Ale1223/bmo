# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::WebService::User;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::WebService);

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Group;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::Util qw(trim detaint_natural mojo_user_agent);
use Bugzilla::WebService::Util qw(filter filter_wants validate
  translate params_to_objects);
use Bugzilla::Hook;

use Digest::HMAC_SHA1 qw(hmac_sha1_hex);
use List::Util qw(first);
use Mojo::JSON qw(true);
use Try::Tiny;

# Don't need auth to login
use constant LOGIN_EXEMPT => {login => 1, offer_account_by_email => 1,};

use constant READ_ONLY => qw(
  get
  suggest
);

use constant PUBLIC_METHODS => qw(
  create
  get
  login
  logout
  offer_account_by_email
  update
  valid_login
  whoami
);

use constant MAPPED_FIELDS =>
  {email => 'login', full_name => 'name', login_denied_text => 'disabledtext',};

use constant MAPPED_RETURNS => {
  login_name   => 'email',
  realname     => 'full_name',
  disabledtext => 'login_denied_text',
};

##############
# User Login #
##############

sub login {
  my ($self, $params) = @_;

  # Check to see if we are already logged in
  my $user = Bugzilla->user;
  if ($user->id) {
    return $self->_login_to_hash($user);
  }

  # Username and password params are required
  foreach my $param ("login", "password") {
    (defined $params->{$param} || defined $params->{'Bugzilla_' . $param})
      || ThrowCodeError('param_required', {param => $param});
  }

  $user = Bugzilla->login();
  return $self->_login_to_hash($user);
}

sub logout {
  my $self = shift;
  Bugzilla->logout;
}

sub valid_login {
  my ($self, $params) = @_;
  defined $params->{login}
    || ThrowCodeError('param_required', {param => 'login'});
  Bugzilla->login();
  if (Bugzilla->user->id && Bugzilla->user->login eq $params->{login}) {
    return $self->type('boolean', 1);
  }
  return $self->type('boolean', 0);
}

#################
# User Creation #
#################

sub offer_account_by_email {
  my $self     = shift;
  my ($params) = @_;
  my $email    = trim($params->{email})
    || ThrowCodeError('param_required', {param => 'email'});

  Bugzilla->user->check_account_creation_enabled;
  Bugzilla->user->check_and_send_account_creation_confirmation($email);
  return undef;
}

sub create {
  my $self = shift;
  my ($params) = @_;

  Bugzilla->user->in_group('editusers')
    || ThrowUserError("auth_failure",
    {group => "editusers", action => "add", object => "users"});

  my $email = trim($params->{email})
    || ThrowCodeError('param_required', {param => 'email'});

  my $data = {
    login_name    => $email,
    realname      => trim($params->{full_name}),
    cryptpassword => trim($params->{password}) || '*',
  };

  if (my $iam_username = trim($params->{iam_username})) {
    $data->{iam_username} = $iam_username;
  }

  my $user = Bugzilla::User->create($data);

  return {id => $self->type('int', $user->id)};
}

sub suggest {
  my ($self, $params) = @_;

  Bugzilla->switch_to_shadow_db();

  ThrowCodeError('params_required',
    {function => 'User.suggest', params => ['match']})
    unless defined $params->{match};

  ThrowUserError('user_access_by_match_denied') unless Bugzilla->user->id;

  my $s = $params->{match};
  trim($s);
  return {users => []} if length($s) < 3;

  my $dbh    = Bugzilla->dbh;
  my @select = ('userid AS id');
  my $order  = 'last_activity_ts DESC';
  my $where;
  state $have_mysql = $dbh->isa('Bugzilla::DB::Mysql');

  if ($s =~ /^[:@](.+)$/s) {
    $where = $dbh->sql_prefix_match(nickname => $1);
  }
  elsif ($s =~ /@/) {
    $where = $dbh->sql_prefix_match(login_name => $s);
  }
  else {
    if ($have_mysql && ($s =~ /[[:space:]]/ || $s =~ /[^[:ascii:]]/)) {
      my $match = $dbh->sql_prefix_match_fulltext('realname', $s);
      push @select, "$match AS relevance";
      $order = 'relevance DESC';
      $where = $match;
    }
    elsif ($have_mysql && $s =~ /^[[:upper:]]/) {
      my $match = $dbh->sql_prefix_match_fulltext('realname', $s);
      $where = join ' OR ', $match, $dbh->sql_prefix_match(nickname => $s),
        $dbh->sql_prefix_match(login_name => $s);
    }
    else {
      $where = join ' OR ', $dbh->sql_prefix_match(nickname => $s),
        $dbh->sql_prefix_match(login_name => $s);
    }
  }
  $where = "($where) AND is_enabled = 1";

  my $results = $dbh->selectall_arrayref(
    "SELECT "
      . join(', ', @select)
      . " FROM profiles WHERE $where ORDER BY $order LIMIT 25",
    {Slice => {}}
  );
  my $user_objects = Bugzilla::User->new_from_list([map { $_->{id} } @$results]);

  my @user_data = map { {
    id        => $self->type('int',    $_->id),
    real_name => $self->type('string', $_->name),
    nick      => $self->type('string', $_->nick),
    name      => $self->type('email',  $_->login),
  } } @$user_objects;

  Bugzilla::Hook::process(
    'webservice_user_get',
    {
      webservice   => $self,
      params       => $params,
      user_data    => \@user_data,
      user_objects => $user_objects
    }
  );

  return {users => \@user_data};
}

# function to return user information by passing either user ids or
# login names or both together:
# $call = $rpc->call( 'User.get', { ids => [1,2,3],
#         names => ['testusera@redhat.com', 'testuserb@redhat.com'] });
sub get {
  my ($self, $params)
    = validate(@_, 'names', 'ids', 'match', 'group_ids', 'groups');

  Bugzilla->switch_to_shadow_db();

       defined($params->{names})
    || defined($params->{ids})
    || defined($params->{match})
    || ThrowCodeError('params_required',
    {function => 'User.get', params => ['ids', 'names', 'match']});

  my (@user_objects, @faults);
  if ($params->{names}) {
    foreach my $name (@{$params->{names}}) {
      my $user;
      # If permissive mode, then we do not kill the whole
      # request if there is an error with user lookup.
      # We store the errors in 'faults' array.
      if ($params->{permissive}) {
        my $old_error_mode = Bugzilla->error_mode;
        Bugzilla->error_mode(ERROR_MODE_DIE);
        eval { $user = Bugzilla::User->check({name => $name}); };
        Bugzilla->error_mode($old_error_mode);
        if ($@) {
          push @faults, {name => $name, error => true, message => $@->message};
          undef $@;
          next;
        }
        push @user_objects, $user;
      }
      else {
        push @user_objects, Bugzilla::User->check({name => $name});
      }
    }
  }

  # start filtering to remove duplicate user ids
  my %unique_users = map { $_->id => $_ } @user_objects;
  @user_objects = values %unique_users;

  my @users;

  # If the user is not logged in: Return an error if they passed any user ids.
  # Otherwise, return a limited amount of information based on login names.
  if (!Bugzilla->user->id) {
    if ($params->{ids}) {
      ThrowUserError("user_access_by_id_denied");
    }
    if ($params->{match}) {
      ThrowUserError('user_access_by_match_denied');
    }
    my $in_group = $self->_filter_users_by_group(\@user_objects, $params);
    @users = map {
      filter $params,
        {
        id        => $self->type('int',    $_->id),
        real_name => $self->type('string', $_->name),
        nick      => $self->type('string', $_->nick),
        name      => $self->type('email',  $_->login),
        }
    } @$in_group;

    return {users => \@users, faults => \@faults};
  }

  my $obj_by_ids;
  $obj_by_ids = Bugzilla::User->new_from_list($params->{ids}) if $params->{ids};

  # obj_by_ids are only visible to the user if they can see
  # the otheruser, for non visible otheruser throw an error
  foreach my $obj (@$obj_by_ids) {
    if (Bugzilla->user->can_see_user($obj)) {
      if (!$unique_users{$obj->id}) {
        push(@user_objects, $obj);
        $unique_users{$obj->id} = $obj;
      }
    }
    else {
      ThrowUserError(
        'auth_failure',
        {
          reason => "not_visible",
          action => "access",
          object => "user",
          userid => $obj->id
        }
      );
    }
  }

  # User Matching
  my $limit;
  if ($params->{limit}) {
    detaint_natural($params->{limit})
      || ThrowCodeError('param_must_be_numeric',
      {function => 'User.match', param => 'limit'});
    $limit = $limit ? min($params->{limit}, $limit) : $params->{limit};
  }
  my $exclude_disabled = $params->{'include_disabled'} ? 0 : 1;
  foreach my $match_string (@{$params->{'match'} || []}) {
    my $matched = Bugzilla::User::match($match_string, $limit, $exclude_disabled);
    foreach my $user (@$matched) {
      if (!$unique_users{$user->id}) {
        push(@user_objects, $user);
        $unique_users{$user->id} = $user;
      }
    }
  }

  my $in_group = $self->_filter_users_by_group(\@user_objects, $params);
  foreach my $user (@$in_group) {
    my $user_info = filter $params,
      {
      id                 => $self->type('int',      $user->id),
      real_name          => $self->type('string',   $user->name),
      nick               => $self->type('string',   $user->nick),
      name               => $self->type('email',    $user->login),
      email              => $self->type('email',    $user->email),
      can_login          => $self->type('boolean',  $user->is_enabled ? 1 : 0),
      iam_username       => $self->type('string',   $user->iam_username),
      last_seen_date     => $self->type('dateTime', $user->last_seen_date),
      creation_time      => $self->type('dateTime', $user->creation_ts),
      };

    if (Bugzilla->user->in_group('disableusers')) {
      if (filter_wants($params, 'email_enabled')) {
        $user_info->{email_enabled} = $self->type('boolean', $user->email_enabled);
      }
      if (filter_wants($params, 'login_denied_text')) {
        $user_info->{login_denied_text} = $self->type('string', $user->disabledtext);
      }
    }

    if (Bugzilla->user->id == $user->id) {
      if (filter_wants($params, 'saved_searches')) {
        $user_info->{saved_searches}
          = [map { $self->_query_to_hash($_) } @{$user->queries}];
      }
    }

    if (filter_wants($params, 'groups')) {
      if ( Bugzilla->user->id == $user->id
        || Bugzilla->user->in_group('mozilla-employee-confidential'))
      {
        $user_info->{groups} = [map { $self->_group_to_hash($_) } @{$user->groups}];
      }
      else {
        $user_info->{groups} = $self->_filter_bless_groups($user->groups);
      }
    }

    push(@users, $user_info);
  }

  Bugzilla::Hook::process(
    'webservice_user_get',
    {
      webservice   => $self,
      params       => $params,
      user_data    => \@users,
      user_objects => $in_group,
    }
  );

  return {users => \@users, faults => \@faults};
}

###############
# User Update #
###############

sub update {
  my ($self, $params) = @_;

  my $dbh = Bugzilla->dbh;

  my $user = Bugzilla->login(LOGIN_REQUIRED);

  # Reject access if there is no sense in continuing.
  $user->in_group('editusers')
    || ThrowUserError("auth_failure",
    {group => "editusers", action => "edit", object => "users"});

  defined($params->{names})
    || defined($params->{ids})
    || ThrowCodeError('params_required',
    {function => 'User.update', params => ['ids', 'names']});

  my $user_objects = params_to_objects($params, 'Bugzilla::User');

  my $values = translate($params, MAPPED_FIELDS);

  # We delete names and ids to keep only new values to set.
  delete $values->{names};
  delete $values->{ids};

  $dbh->bz_start_transaction();
  foreach my $user (@$user_objects) {
    $user->set_all($values);
  }

  my %changes;
  foreach my $user (@$user_objects) {
    my $returned_changes = $user->update();
    $changes{$user->id} = translate($returned_changes, MAPPED_RETURNS);
  }
  $dbh->bz_commit_transaction();

  my @result;
  foreach my $user (@$user_objects) {
    my %hash = (id => $user->id, changes => {},);

    foreach my $field (keys %{$changes{$user->id}}) {
      my $change = $changes{$user->id}->{$field};

      # We normalize undef to an empty string, so that the API
      # stays consistent for things that can become empty.
      $change->[0] = '' if !defined $change->[0];
      $change->[1] = '' if !defined $change->[1];

      # We also flatten arrays (used by groups and blessed_groups)
      $change->[0] = join(',', @{$change->[0]}) if ref $change->[0];
      $change->[1] = join(',', @{$change->[1]}) if ref $change->[1];

      $hash{changes}{$field} = {
        removed => $self->type('string', $change->[0]),
        added   => $self->type('string', $change->[1])
      };
    }

    push(@result, \%hash);
  }

  return {users => \@result};
}

sub _filter_users_by_group {
  my ($self, $users, $params) = @_;
  my ($group_ids, $group_names) = @$params{qw(group_ids groups)};

  # If no groups are specified, we return all users.
  return $users if (!$group_ids and !$group_names);

  my $user = Bugzilla->user;

  my @groups = map { Bugzilla::Group->check({id => $_}) } @{$group_ids || []};

  if ($group_names) {
    foreach my $name (@$group_names) {
      my $group
        = Bugzilla::Group->check({name => $name, _error => 'invalid_group_name'});
      $user->in_group($group)
        || ThrowUserError('invalid_group_name', {name => $name});
      push(@groups, $group);
    }
  }

  my @in_group = grep { $self->_user_in_any_group($_, \@groups) } @$users;
  return \@in_group;
}

sub _user_in_any_group {
  my ($self, $user, $groups) = @_;
  foreach my $group (@$groups) {
    return 1 if $user->in_group($group);
  }
  return 0;
}

sub _filter_bless_groups {
  my ($self, $groups) = @_;
  my $user = Bugzilla->user;

  my @filtered_groups;
  foreach my $group (@$groups) {
    next unless ($user->in_group('editusers') || $user->can_bless($group->id));
    push(@filtered_groups, $self->_group_to_hash($group));
  }

  return \@filtered_groups;
}

sub _group_to_hash {
  my ($self, $group) = @_;
  my $item = {
    id          => $self->type('int',    $group->id),
    name        => $self->type('string', $group->name),
    description => $self->type('string', $group->description),
  };
  return $item;
}

sub _query_to_hash {
  my ($self, $query) = @_;
  my $item = {
    id   => $self->type('int',    $query->id),
    name => $self->type('string', $query->name),
    url  => $self->type('string', $query->url),
  };

  return $item;
}

sub _login_to_hash {
  my ($self, $user) = @_;
  my $item = {id => $self->type('int', $user->id)};
  if (my $login_token = $user->{_login_token}) {
    $item->{'token'} = $user->id . "-" . $login_token;
  }
  return $item;
}

#
# MFA
#

sub mfa_enroll {
  my ($self, $params) = @_;
  my $provider_name = lc($params->{provider});

  my $user = Bugzilla->login(LOGIN_REQUIRED);
  $user->set_mfa($provider_name);
  my $provider = $user->mfa_provider // die "Unknown MFA provider\n";
  return $provider->enroll_api();
}

sub whoami {
  my ($self, $params) = @_;
  my $user = _user_from_phab_token() || Bugzilla->login(LOGIN_REQUIRED);

  # Generate a deterministic ID from the site-wide-secret and user-id.
  # This can be used for user tracking in other systems without the
  # ability to trace the ID back to a specific Bugzilla account.
  my $uuid = hmac_sha1_hex($user->id, Bugzilla->localconfig->site_wide_secret);

  return filter(
    $params,
    {
      id           => $self->type('int',     $user->id),
      real_name    => $self->type('string',  $user->name),
      nick         => $self->type('string',  $user->nick),
      name         => $self->type('email',   $user->login),
      mfa_status   => $self->type('boolean', !!$user->mfa),
      groups       => [map { $_->name } @{$user->groups}],
      uuid         => $self->type('string',  'bmo-who:' . $uuid),
      iam_username => $self->type('string',  $user->iam_username),
    }
  );
}

sub _user_from_phab_token {

  # BMO - If a token is provided in the X-PHABRICATOR-TOKEN header, we use that
  # to request the associated email address from Phabricator via its
  # `user.whoami` endpoint.

  # only if PhabBugz is configure and X-PHABRICATOR-TOKEN is provided
  (my $phab_url = Bugzilla->params->{phabricator_base_uri}) =~ s{/$}{};
  my $phab_token = Bugzilla->input_params->{Phabricator_token};
  return undef unless $phab_url && $phab_token;

  try {
    # query phabricator's whoami endpoint
    my $ua = mojo_user_agent({request_timeout => 5});
    $ua->transactor->name('BMO user.whoami shim');
    my $res = $ua->get(
      "$phab_url/api/user.whoami" => form => {'api.token' => $phab_token});
    my $ph_whoami = $res->result->json;

    # treat any phabricator generated error as an invalid api-key
    if (my $error = $ph_whoami->{error_info}) {
      DEBUG("Phabricator user.whoami failed: $error");
      ThrowUserError("api_key_not_valid");
    }

    # load user from primaryEmail
    my $user = Bugzilla::User->new(
      {name => $ph_whoami->{result}->{primaryEmail}, cache => 1});
    if (!$user) {
      DEBUG("No Bugzilla user for Phabricator email: "
            . $ph_whoami->{result}->{primaryEmail});
      ThrowUserError("api_key_not_valid");
    }
    return $user;
  }
  catch {
    WARN("Request to $phab_url failed: $_");
    ThrowUserError("api_key_not_valid");
  };
}

1;

__END__

=head1 NAME

Bugzilla::Webservice::User - The User Account and Login API

=head1 DESCRIPTION

This part of the Bugzilla API allows you to create User Accounts and
log in/out using an existing account.

=head1 METHODS

See L<Bugzilla::WebService> for a description of how parameters are passed,
and what B<STABLE>, B<UNSTABLE>, and B<EXPERIMENTAL> mean.

Although the data input and output is the same for JSON-RPC, XML-RPC and REST,
the directions for how to access the data via REST is noted in each method
where applicable.

=head1 Logging In and Out

These method are now deprecated, and will be removed in the release after
Bugzilla 5.0. The correct way of use these REST and RPC calls is noted in
L<Bugzilla::WebService>

=head2 login

B<DEPRECATED>

=over

=item B<Description>

Logging in, with a username and password, is required for many
Bugzilla installations, in order to search for bugs, post new bugs,
etc. This method logs in an user.

=item B<Params>

=over

=item C<login> (string) - The user's login name.

=item C<password> (string) - The user's password.

=item C<remember> (bool) B<Optional> - if the cookies returned by the
call to login should expire with the session or not.  In order for
this option to have effect the Bugzilla server must be configured to
allow the user to set this option - the Bugzilla parameter
I<rememberlogin> must be set to "defaulton" or
"defaultoff". Additionally, the client application must implement
management of cookies across sessions.

=back

=item B<Returns>

On success, a hash containing two items, C<id>, the numeric id of the
user that was logged in, and a C<token> which can be passed in
the parameters as authentication in other calls. A set of HTTP cookies
is also sent with the response. These cookies *or* the token can be sent
along with any future requests to the webservice, for the duration of the
session. Note that cookies are not accepted for GET requests for JSON-RPC
and REST for security reasons. You may, however, use the token or valid
login parameters for those requests.

=item B<Errors>

=over

=item 300 (Invalid Username or Password)

The username does not exist, or the password is wrong.

=item 301 (Account Disabled)

The account has been disabled.  A reason may be specified with the
error.

=item 305 (New Password Required)

The current password is correct, but the user is asked to change
their password.

=item 50 (Param Required)

A login or password parameter was not provided.

=back

=item B<History>

=over

=item C<token> was added in Bugzilla B<4.4.3>.

=item This function will be removed in the release after Bugzilla 5.0, in favor of API keys.

=back

=back

=head2 logout

B<DEPRECATED>

=over

=item B<Description>

Log out the user. Does nothing if there is no user logged in.

=item B<Params> (none)

=item B<Returns> (nothing)

=item B<Errors> (none)

=back

=head2 valid_login

B<DEPRECATED>

=over

=item B<Description>

This method will verify whether a client's cookies or current login
token is still valid or have expired. A valid username must be provided
as well that matches.

=item B<Params>

=over

=item C<login>

The login name that matches the provided cookies or token.

=item C<token>

(string) Persistent login token current being used for authentication (optional).
Cookies passed by client will be used before the token if both provided.

=back

=item B<Returns>

Returns true/false depending on if the current cookies or token are valid
for the provided username.

=item B<Errors> (none)

=item B<History>

=over

=item Added in Bugzilla B<5.0>.

=item This function will be removed in the release after Bugzilla 5.0, in favor of API keys.

=back

=back

=head1 Account Creation and Modification

=head2 offer_account_by_email

B<STABLE>

=over

=item B<Description>

Sends an email to the user, offering to create an account.  The user
will have to click on a URL in the email, and choose their password
and real name.

This is the recommended way to create a Bugzilla account.

=item B<Param>

=over

=item C<email> (string) - the email to send the offer to.

=back

=item B<Returns> (nothing)

=item B<Errors>

=over

=item 500 (Account Already Exists)

An account with that email address already exists in Bugzilla.

=item 501 (Illegal Email Address)

This Bugzilla does not allow you to create accounts with the format of
email address you specified. Account creation may be entirely disabled.

=back

=back

=head2 create

B<STABLE>

=over

=item B<Description>

Creates a user account directly in Bugzilla, password and all.
Instead of this, you should use L</offer_account_by_email> when
possible, because that makes sure that the email address specified can
actually receive an email. This function does not check that.

You must be logged in and have the C<editusers> privilege in order to
call this function.

=item B<REST>

POST /user

The params to include in the POST body as well as the returned data format,
are the same as below.

=item B<Params>

=over

=item C<email> (string) - The email address for the new user.

=item C<full_name> (string) B<Optional> - The user's full name. Will
be set to empty if not specified.

=item C<password> (string) B<Optional> - The password for the new user
account, in plain text.  It will be stripped of leading and trailing
whitespace.  If blank or not specified, the newly created account will
exist in Bugzilla, but will not be allowed to log in using DB
authentication until a password is set either by the user (through
resetting their password) or by the administrator.

=item C<iam_username> (string) B<optional> - The IAM username used
to authenticate with using an external IAM system.

=back

=item B<Returns>

A hash containing one item, C<id>, the numeric id of the user that was
created.

=item B<Errors>

The same as L</offer_account_by_email>. If a password is specified,
the function may also throw:

=over

=item 502 (Password Too Short)

The password specified is too short. (Usually, this means the
password is under three characters.)

=back

=item B<History>

=over

=item Error 503 (Password Too Long) removed in Bugzilla B<3.6>.

=item REST API call added in Bugzilla B<5.0>.

=back

=back

=head2 update

B<EXPERIMENTAL>

=over

=item B<Description>

Updates user accounts in Bugzilla.

=item B<Params>

=over

=item C<ids>

C<array> Contains ids of user to update.

=item C<names>

C<array> Contains email/login of user to update.

=item C<full_name>

C<string> The new name of the user.

=item C<email>

C<string> The email of the user. Note that email used to login to Bugzilla.
Also note that you can only update one user at a time when changing the
login name / email. (An error will be thrown if you try to update this field
for multiple users at once.)

=item C<iam_username>

C<string> The IAM username used to authenticate with using an external IAM system.

=item C<password>

C<string> The password of the user.

=item C<email_enabled>

C<boolean> A boolean value to enable/disable sending bug-related mail to the user.

=item C<login_denied_text>

C<string> A text field that holds the reason for disabling a user from logging
into Bugzilla, if empty then the user account is enabled otherwise it is
disabled/closed.

=item C<groups>

C<hash> These specify the groups that this user is directly a member of.
To set these, you should pass a hash as the value. The hash may contain
the following fields:

=over

=item C<add> An array of C<int>s or C<string>s. The group ids or group names
that the user should be added to.

=item C<remove> An array of C<int>s or C<string>s. The group ids or group names
that the user should be removed from.

=item C<set> An array of C<int>s or C<string>s. An exact set of group ids
and group names that the user should be a member of. NOTE: This does not
remove groups from the user where the person making the change does not
have the bless privilege for.

If you specify C<set>, then C<add> and C<remove> will be ignored. A group in
both the C<add> and C<remove> list will be added. Specifying a group that the
user making the change does not have bless rights will generate an error.

=back

=item C<set_bless_groups>

C<hash> - This is the same as set_groups, but affects what groups a user
has direct membership to bless that group. It takes the same inputs as
set_groups.

=back

=item B<Returns>

A C<hash> with a single field "users". This points to an array of hashes
with the following fields:

=over

=item C<id>

C<int> The id of the user that was updated.

=item C<changes>

C<hash> The changes that were actually done on this user. The keys are
the names of the fields that were changed, and the values are a hash
with two keys:

=over

=item C<added>

C<string> The values that were added to this field,
possibly a comma-and-space-separated list if multiple values were added.

=item C<removed>

C<string> The values that were removed from this field, possibly a
comma-and-space-separated list if multiple values were removed.

=back

=back

=item B<Errors>

=over

=item 51 (Bad Login Name)

You passed an invalid login name in the "names" array.

=item 304 (Authorization Required)

Logged-in users are not authorized to edit other users.

=back

=back

=head1 User Info

=head2 get

B<STABLE>

=over

=item B<Description>

Gets information about user accounts in Bugzilla.

=item B<REST>

To get information about a single user:

GET /user/<user_id_or_name>

To search for users by name, group using URL params same as below:

GET /user

The returned data format is the same as below.

=item B<Params>

B<Note>: At least one of C<ids>, C<names>, or C<match> must be specified.

B<Note>: Users will not be returned more than once, so even if a user
is matched by more than one argument, only one user will be returned.

In addition to the parameters below, this method also accepts the
standard L<include_fields|Bugzilla::WebService/include_fields> and
L<exclude_fields|Bugzilla::WebService/exclude_fields> arguments.

=over

=item C<ids> (array)

An array of integers, representing user ids.

Logged-out users cannot pass this parameter to this function. If they try,
they will get an error. Logged-in users will get an error if they specify
the id of a user they cannot see.

=item C<names> (array)

An array of login names (strings).

=item C<match> (array)

An array of strings. This works just like "user matching" in
Bugzilla itself. Users will be returned whose real name or login name
contains any one of the specified strings. Users that you cannot see will
not be included in the returned list.

Some Bugzilla installations have user-matching turned off, in which
case you will only be returned exact matches.

Most installations have a limit on how many matches are returned for
each string, which defaults to 1000 but can be changed by the Bugzilla
administrator.

Logged-out users cannot use this argument, and an error will be thrown
if they try. (This is to make it harder for spammers to harvest email
addresses from Bugzilla, and also to enforce the user visibility
restrictions that are implemented on some Bugzillas.)

=item C<group_ids> (array)

=item C<groups> (array)

C<group_ids> is an array of numeric ids for groups that a user can be in.
C<groups> is an array of names of groups that a user can be in.
If these are specified, they limit the return value to users who are
in I<any> of the groups specified.

=item C<include_disabled> (boolean)

By default, when using the C<match> parameter, disabled users are excluded
from the returned results unless their full username is identical to the
match string. Setting C<include_disabled> to C<true> will include disabled
users in the returned results even if their username doesn't fully match
the input string.

=item B<History>

=over

=item REST API call added in Bugzilla B<5.0>.

=back

=back

=item B<Returns>

A hash containing one item, C<users>, that is an array of
hashes. Each hash describes a user, and has the following items:

=over

=item id

C<int> The unique integer ID that Bugzilla uses to represent this user.
Even if the user's login name changes, this will not change.

=item real_name

C<string> The actual name of the user. May be blank.

=item nick

C<string> The user's nickname. Currently this is extracted from the real_name,
name or email field.

=item email

C<string> The email address of the user.

=item name

C<string> The login name of the user. Note that in some situations this is
different than their email.

=item can_login

C<boolean> A boolean value to indicate if the user can login into Bugzilla.

=item email_enabled

C<boolean> A boolean value to indicate if bug-related mail will be sent
to the user or not.

=item login_denied_text

C<string> A text field that holds the reason for disabling a user from logging
into Bugzilla, if empty then the user account is enabled. Otherwise it is
disabled/closed.

=item groups

C<array> An array of group hashes the user is a member of. Each hash describes
the group and contains the following items:

=over

=item id

C<int> The group id

=item name

C<string> The name of the group

=item description

C<string> The description for the group

=back

=over

=item saved_searches

C<array> An array of hashes, each of which represents a user's saved search and has
the following keys:

=over

=item id

C<int> An integer id uniquely identifying the saved search.

=item name

C<string> The name of the saved search.

=item url

C<string> The CGI parameters for the saved search.

=back

B<Note>: The elements of the returned array (i.e. hashes) are ordered by the
name of each saved search.

=back

B<Note>: If you are not logged in to Bugzilla when you call this function, you
will only be returned the C<id>, C<name>, C<real_name> and C<nick> items. If you
are logged in and not in editusers group, you will only be returned the C<id>,
C<name>, C<real_name>, C<nick>, C<email> and C<can_login> items. The groups
returned are filtered based on your permission to bless each group.

=back

=item B<Errors>

=over

=item 51 (Bad Login Name or Group ID)

You passed an invalid login name in the "names" array or a bad
group ID in the C<group_ids> argument.

=item 304 (Authorization Required)

You are logged in, but you are not authorized to see one of the users you
wanted to get information about by user id.

=item 505 (User Access By Id or User-Matching Denied)

Logged-out users cannot use the "ids" or "match" arguments to this
function.

=item 804 (Invalid Group Name)

You passed a group name in the C<groups> argument which either does not
exist or you do not belong to it.

=back

=item B<History>

=over

=item Added in Bugzilla B<3.4>.

=item C<group_ids> and C<groups> were added in Bugzilla B<4.0>.

=item C<include_disabled> added in Bugzilla B<4.0>. Default behavior
for C<match> has changed to only returning enabled accounts.

=item C<groups> Added in Bugzilla B<4.4>.

=item C<saved_searches> Added in Bugzilla B<4.4>.

=item Error 804 has been added in Bugzilla 4.0.9 and 4.2.4. It's now
illegal to pass a group name you don't belong to.

=item C<nick> Added in Bugzilla B<6.0>.

=back

=item REST API call added in Bugzilla B<5.0>.

=back

=head2 whoami

=over

=item B<Description>

Allows for validating a user's API key, token, or username and password.
If successfully authenticated, it returns simple information about the
logged in user.

=item B<Params> (none)

=item B<Returns>

On success, a hash containing information about the logged in user.

=over

=item id

C<int> The unique integer ID that Bugzilla uses to represent this user.
Even if the user's login name changes, this will not change.

=item real_name

C<string> The actual name of the user. May be blank.

=item nick

C<string> The user's nickname. Currently this is extracted from the real_name,
name or email field.

=item name

C<string> The login name of the user.

=back

=item B<Errors>

=over

=item 300 (Invalid Username or Password)

The username does not exist, or the password is wrong.

=item 301 (Account Disabled)

The account has been disabled.  A reason may be specified with the
error.

=item 305 (New Password Required)

The current password is correct, but the user is asked to change
their password.

=back

=back
