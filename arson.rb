# General Design:
#
# The Jabber End:
# 
# We create a jabber component, campfire.localhost or similar, use it
# to create a MUC for each campfire room, and also use it to create
# virtual users to join the MUCs, one for each campfire user.
#
# The component does this by having callbacks for, and responding
# appropriately to, arbirtary presence and message stanza that come in
# to its component name; see
# http://xmpp.org/extensions/xep-0045.html for details of the MUC
# messages.
# 
# When a message from a real user comes in on the Jabber end, we use
# the name that it came in on to find a Campfire user name to send it
# out as.
#
# Note that each virtual MUC and associated set of virtual users is
# per-real-user; no real user can see or connect to any other real
# user's jabber/campfire rooms on the component, since they don't
# "actually exist"; the component just responds as though there are
# a bunch of MUCs and users.
# 
# It is worth noting that xmpp4r is not actually prepared to be a
# component supporting a bunch of virtual MUCs and users, at all, so
# we have to manually construct our own presence messages in a lot of
# cases.
#
# The Campfire End:
# 
# For each user, we log in to Campfire with their token.  Then we make
# a thread for each room, and stream messages in that thread.  Any
# kick or leave or join message causes the list of MUC virtual users
# to get re-evaluated.  Any actual message gets passed to the Jabber
# room, with some special handling for things like pastes and uploads.
# 
# We also launch another thread that simply re-asserts each token's
# presence in each room every minute, because Campfire has this
# annoying habit of losing track.  It also checks nicks, for similar
# reasons.


require 'rubygems'
require 'broach'
require 'daemons'
require 'uri'
require 'yajl/http_stream'
require 'logger'
require 'xmpp4r'
require 'xmpp4r/muc'
require 'xmpp4r/component'
require 'xmpp4r/roster'
require 'yaml'
require 'ArsonConfig'


#**************************************************
# Globals
#**************************************************
$jabber_component = nil
$log = nil
$users = nil

#**************************************************
# Support Functions
#
# If you're looking for the main program flow, search for "Daemons"
#**************************************************

# Send stuff to jabber with retries
def jabber_send( stuff )
  begin
    $jabber_component.send(stuff)
  rescue Exception => e
    $log.info( "Couldn't send to jabber due to error: " )
    $log.info( e )
    jabber_reset
  end
end

# This code is making up for the fact that xmpp4r doesn't know how
# to generate the presence stanzas we need in any clean fashion.
def send_presence( from, to, type, xmuc=false, affiliation=nil, role=nil, reason=nil, status_codes=nil, item_jid=nil )
  $log.debug( "In send_presence: #{from}, #{to}, #{type}, #{xmuc}, #{affiliation}, #{role}, #{reason}, #{status_codes}" )
  presence = Jabber::Presence.new.set_from( from )
  presence.set_to( to ).set_type( type )

  if xmuc
    xelem = presence.add_element('x', { 'xmlns' => 'http://jabber.org/protocol/muc#user' } )
    #print "presence: #{YAML::dump(presence)}\n"

    if affiliation and role
      if item_jid
        itemelem = xelem.add_element( 'item', { 'affiliation' => affiliation, 'role' => role, 'jid' => item_jid } )
      else
        itemelem = xelem.add_element( 'item', { 'affiliation' => affiliation, 'role' => role } )
      end
      if reason
        itemelem.add_element( 'reason' ).add_text( reason )
      end
      #print "presence: #{YAML::dump(presence)}\n"
    end

    if status_codes
      status_codes.each do |code|
        xelem.add_element( 'status', { 'code' => code } )
      end
      #print "presence: #{YAML::dump(presence)}\n"
    end

    jabber_send(presence)
  end
end

# Updates the list of nicks in a virtual Jabber room.
#
# First we grab all the users in the room
#
# Then we loop through all the users in the room and make sure they
# exist in the MUC
#
# Then we loop through all the users in the MUC and make sure they
# exist in the room.
#
# There's certainly better ways to do that (like set substraction),
# but we're talking about very small lists so enh.
#
# The "realuser" argument is the full user structure for the user in
# question; it's used by make_muc_user to find out what sorts of name
# layouts the user prefers.
#
def fix_nicks( room, realuser )
  campfire_room_id = room['campfire_room_id']

  room_info = room['broach_session'].get("room/#{campfire_room_id}.json")
  $log.debug("fix_nicks: users according to campfire for room #{room['jabber_room_name']} : #{YAML::dump(room_info['room']['users'].map { |u| u['name'] })}")
  $log.debug("fix_nicks: users according to us for room #{room['jabber_room_name']} : #{YAML::dump(room['jabber_users'])}")

  # Check that every room user has a MUC equivalent
  room_info['room']['users'].each do |user|
    uname = user['name']
    # Check if the user is in jabber
    if ! room['jabber_users'][uname]
      # Ignore the real user's campfire name
      if room['campfire_user_name'] != uname then
        make_muc_user( room, realuser, uname )
      end
    else
      # The user is already in jabber, but send the presence anyways
      $log.debug( "fix_nicks: Send presence for #{uname} with name #{room['jabber_users'][uname]}" )
      make_muc_user_final( room, room['jabber_users'][uname] )
    end
  end

  # Check that every MUC user is still in the Campfire room
  room['jabber_users'].keys.each do |uname|
    if ! room_info['room']['users'].find { |user| user['name'] == uname }
      drop_muc_user( room, uname )
    end
  end
end

# Takes a Campfire name and turns it into the jabber nick
# appropriate for the room in question.
def name_to_jabber_nick( name, room )
  usename = name
  if room['jabber_users'].has_key?( name )
    usename = room['jabber_users'][name]
  else
    $log.info( "In name_to_jabber_nick, unknown nick #{name}." )
  end
  return slugify_name( usename )
end

def slugify_name( name )
  return name.gsub(/-+\&$/,'')
end

# Just the first word
def name_first( name )
  return name.split[0]
end

# Just the first word and the first letter of the next word
def name_firstni( name )
  splitted=name.split
  if splitted.length < 2
    return splitted[0]
  else
    return splitted[0]+"_"+splitted[1][0,1]
  end
end

# Returns the name format of the user preference type given.
def preferred_name( type, name )
  $log.debug( "In preferred_name; type #{type}, name #{name}" )
  case type
  when "first"
    return name_first( name )
  when "firstni"
    return name_firstni( name )
  when "all"
    return name.split.join('_')
  else
    $log.fatal( "Invalid name handling type #{type}; check the user config files." )
    exit 1
  end
end

# Check whether a given name already exists in a given room
def check_name_conflict( name, room )
  $log.debug( "In check_name_conflict, name #{name}, room names #{room['jabber_users']}" )
  #$log.debug( "In check_name_conflict, name #{name}, room names #{YAML::dump(room['jabber_users'])}" )
  conflict = false
  conflict = room['jabber_users'].keys.detect { |fullname| room['jabber_users'][fullname] == name }
  $log.debug( "In check_name_conflict, returning #{conflict}" )
  return conflict
end

# utility function for make_muc_user; does the actual presence
# generaton
def make_muc_user_final( room, usename )
  from = "#{room['jabber_room_name']}@#{ArsonConfig::JabberComponentName}/#{slugify_name(usename)}"

  $log.debug( "in make_muc_user: from: #{from}" )

  send_presence( from, room['user_jid'], nil, true, 'member', 'participant', nil, nil, "#{slugify_name(usename)}@#{ArsonConfig::JabberComponentName}/#{slugify_name(usename)}" )
end

# make_muc_user figures out out what sorts of name layouts the user
# prefers, and makes a jabber user based on a campfire user with that
# sort of name.
def make_muc_user( room, realuser, uname )
  $log.info( "Adding campfire user #{uname} to jabber room #{room['jabber_room_name']} for #{room['user_jid']} \n" )

  # Figure out what the final name actually looks like.
  usename = nil
  wantname = preferred_name( realuser['default_names'], uname )
  if check_name_conflict( wantname, room )
    secondwantname = preferred_name( realuser['similar_names'], uname )
    if check_name_conflict( secondwantname, room )
      # Default to "All"; since we already tested based on uname,
      # which is what we store in the hash, there should be no
      # conflict here

      # The first version wasn't OK; so change whoever the
      # collission was with
      conflictfullname = check_name_conflict( wantname, room )
      drop_muc_user( room, conflictfullname )

      room['jabber_users'][conflictfullname] = conflictfullname

      make_muc_user_final( room, conflictfullname )

      # Save the new user's nick name
      usename = uname
    else
      # The first version wasn't OK; so change whoever the
      # collission was with
      conflictfullname = check_name_conflict( wantname, room )
      conflictnewname = preferred_name( realuser['similar_names'], conflictfullname )
      drop_muc_user( room, conflictfullname )

      room['jabber_users'][conflictfullname] = conflictnewname

      make_muc_user_final( room, conflictnewname )

      # Save the new user's nick name
      usename = secondwantname
    end
  else
    # Save the new user's nick name
    usename = wantname
  end

  room['jabber_users'][uname] = usename

  make_muc_user_final( room, usename )
end

# Takes a user out of the virtual jabber room
def drop_muc_user( room, uname )
  $log.info( "Removing campfire user #{uname} from jabber room #{room['jabber_room_name']}\n" )

  from = "#{room['jabber_room_name']}@#{ArsonConfig::JabberComponentName}/#{name_to_jabber_nick(uname, room)}"

  send_presence( from, room['user_jid'], :unavailable, true, 'none', 'none' )

  room['jabber_users'].delete(uname)
end

# Sends an actual message, rather than a presence stanza, to jabber
def send_to_jabber( room, from_campfire_user_name, our_campfire_user_name, msg )
  $log.debug("In send_to_jabber, message #{msg} from name #{from_campfire_user_name} to jabber room #{room['room_jid']}; our name is #{our_campfire_user_name}")

  if from_campfire_user_name == our_campfire_user_name
    $log.debug("In send_to_jabber, not sending." )
  else
    $log.debug("In send_to_jabber, sending." )
    from = "#{room['jabber_room_name']}@#{ArsonConfig::JabberComponentName}/#{name_to_jabber_nick(from_campfire_user_name, room)}"
    jmess = Jabber::Message.new( room['user_jid'], msg ).set_from( from ).set_type(:groupchat)
    $log.debug("In send_to_jabber, final version: #{YAML::dump(jmess)}")
    jabber_send(jmess)
  end
end

# Sends a message to campfire
def send_to_campfire( room, msg )
  $log.debug("sending #{msg} to campfire room #{room['campfire_room_name']} from user #{room['user_jid']}")
  if msg =~ /^\/me /
    msg.gsub!(/^\/me (.*)/, '*\1*')
    $log.debug("rewritten; sending #{msg} to campfire room #{room['campfire_room_name']}")
  end

  room['broach_session'].post("room/#{room['campfire_room_id']}/speak", 'message' => {
    'type' => 'TextMessage',
    'body' => msg,
  })
end

#*************************
# This is the "make sure camfire knows we're here" section; we just
# loop forever, regularily re-joining the campfire room and checking
# the nick list, because otherwise Campfire seems to get confused.
#
# This is probably way overzealous, but it seems to work.
#*************************
def stay_in_campfire_room( room, user )
  th = Thread.new do
    attached = false
    while true
      begin
        $log.debug("checking room")
        #        $log.debug("check 1: #{room['broach_session'].get("presence.json")['rooms'].inspect} should include id #{room['campfire_room_id']}");
        #        $log.debug("check 2: #{room['broach_session'].get("room/#{room['campfire_room_id']}.json")['room']['users']} should include id #{user['campfire_id']}");

        # if ! room['broach_session'].get("presence.json")['rooms'].detect{ |x| x['id'] == room['campfire_room_id']} or
        #   ! room['broach_session'].get("room/#{room['campfire_room_id']}.json")['room']['users'].
        #   detect{ |x| x['id'] == user['campfire_id']} then

        if attached
          $log.debug( "Already attachd; not attaching to room #{room['campfire_room_name']}, id #{room['campfire_room_id']}, for user #{room['user_jid']}" )
        else
          $log.info( "Attaching to room #{room['campfire_room_name']}, id #{room['campfire_room_id']}, for user #{room['user_jid']}" )
          attached = true
        end

        # This logs us in to the room.  We re-run it
        # periodically because we seem to fall out otherwise.
        #
        # Broach can't handle POST calls that return a flat 200,
        # which is a problem since the API does this repeatedly.
        #
        # FIXME:  Update the next line when that broach bug is
        # fixed

        # REST here is from the nap egg, which is what broach uses
        #        $log.debug( "post: #{room['broach_session'].url_for("room/#{room['campfire_room_id']}/join")}, '', #{YAML::dump(room['broach_session'].headers_for(:post))}, #{YAML::dump(room['broach_session'].credentials)})" )
        REST.post(room['broach_session'].url_for("room/#{room['campfire_room_id']}/join"), '', room['broach_session'].headers_for(:post), room['broach_session'].credentials)
        # end

        # Also check membership, as that sort of thing seems to get
        # lost a fair bit
        fix_nicks( room, user )

        # Make sure the user knows they're still in the room
        send_presence( room['room_jid'], room['user_jid'], nil, true, 'member', 'participant', nil, [ '100', '110', '210' ] )

        # Restart the room watch thread, cuz it seems to drop
        # sometimes.
        if room['http_stream']
          begin
            $log.debug( "In stay_in_campfire_room, doing the loop termination for room #{room['campfire_room_name']}" )
            room['http_stream'].terminate
          rescue SocketError, IOError
            # We don't care about these when we're trying to break
            # the connection.
          end
        else
          $log.debug( "In stay_in_campfire_room, the campfire stream for #{room['campfire_room_name']} isn't ready" )
        end

        sleep 300
      rescue SocketError
        $log.error( "Networking problems in stay attached thread for room #{room['campfire_room_name']} with error: " )
        $log.error( e )
        exit
      rescue SystemExit
        $log.error( "Exit requetsed in stay attached thread for room #{room['campfire_room_name']}." )
        exit
      rescue Exception => e
        attached = false
        $log.error( "Error in stay-attached thread for room #{room['campfire_room_name']}: " )
        $log.error( e )
      end
    end
  end

  return th
end

#************************************************
# Campfire => Jabber Section
#
# Watches the campfire stream, and sends the resulting messages to
# Jabber.  Kicks off a fix_nicks run if it sees something related to
# user joins and leaves.
#************************************************
def campfire_to_jabber( room, user )
  th = Thread.new do
    if room['broach_session'] == nil
      $log.error( "Room #{room['campfire_room_name']} doesn't seem to be working in Broach; perhaps the name is wrong?" )
      break
    end

    $log.debug( "In room thread for #{room['campfire_room_name']}" )

    while true
      $log.debug( "In while in room thread #{Thread.current} for #{room['campfire_room_name']}" )

      sleep 5

      begin
        $log.debug( "In while in room thread for #{room['campfire_room_name']}, top of begin block" )

        url = URI.parse("http://#{user['campfire_token']}:x@streaming.campfirenow.com/room/#{room['campfire_room_id']}/live.json")

        $log.debug( "In room thread for #{room['campfire_room_name']}, streaming url: #{url}" )

        # Stream messages from the campfire room
        room['http_stream'] = Yajl::HttpStream.new()
        
        room['http_stream'].get(url) do |message|
          $log.debug( "In while in room thread #{Thread.current} for #{room['campfire_room_name']}, message: #{message.inspect}" )

          case message['type']
          when "TextMessage", "SoundMessage", "AdvertisementMessage",
            "AllowGuestsMessage", "DisallowGuestsMessage", "IdleMessage", "SystemMessage", 
            "TimestampMessage", "TopicChangeMessage", "UnidleMessage", "UnlockMessage", "TweetMessage"
            if message['body'] != nil and message['user_id'] != nil
              $log.debug( "In while in room thread for #{room['campfire_room_name']}, sending message: #{message['body']}" )
              campfire_user_name=room['broach_session'].get("users/"+message['user_id'].to_s)['user']['name']
              send_to_jabber( room, campfire_user_name, user['campfire_name'], message['body'] )
            end
          when "PasteMessage"
            if message['body'] != nil and message['user_id'] != nil
              campfire_user_name=room['broach_session'].get("users/"+message['user_id'].to_s)['user']['name']
              paste=message['body']
              trimmed=false
              if user.has_key?('paste_length') and user['paste_length'] != 'all'
                origlength = paste.split("\n").length
                if origlength > user['paste_length']
                  paste = paste.split("\n")[0,user['paste_length']].join("\n")
                  trimmed = origlength - user['paste_length']
                end
              end

              paste_url = room['broach_session'].url_for("room/#{room['campfire_room_id']}/paste/#{message['id']}")

              # There are various interactions between the user
              # configs paste_url, paste_style, and paste_length, so
              # this gets a bit complicated.
              case user['paste_style']
              when "plain"
                $log.debug( "In while in room thread for #{room['campfire_room_name']}, sending plain paste" )
                if user['paste_url'] == "only"
                  paste = "PASTE: " + paste_url
                else
                  if user['paste_url'] == true
                    paste = paste_url + ": " + paste
                  end
                  if trimmed
                    paste += "\n... #{trimmed} more lines ..."
                  end
                end
              when "border"
                $log.debug( "In while in room thread for #{room['campfire_room_name']}, sending border paste" )
                if user['paste_url'] == "only"
                  paste = "-- PASTE: #{paste_url} -------------------------------\n"
                else
                  if user['paste_url'] == true
                    paste = "-- START PASTE #{paste_url} -------------------------------\n" + paste
                  else
                    paste = "-- START PASTE -------------------------------\n" + paste
                  end

                  if trimmed
                    paste += "\n-- END PASTE #{trimmed} more lines -------------------------------"
                  else
                    paste += "\n--  END PASTE  -------------------------------"
                  end
                end
              else
                $log.fatal( "Invalid name paste_style #{user['paste_style']}; check the user config files." )
                exit 1
              end
              send_to_jabber( room, campfire_user_name, user['campfire_name'], paste )
            end
          when "UploadMessage"
            if message['body'] != nil and message['user_id'] != nil
              campfire_user_name=room['broach_session'].get("users/"+message['user_id'].to_s)['user']['name']
              $log.debug( "In while in room thread for #{room['campfire_room_name']}, sending upload" )
              upload_url ="room/#{room['campfire_room_id']}/messages/#{message['id']}/upload.json"
              upload_info = room['broach_session'].get(upload_url)
              $log.debug( "upload info from #{upload_url}: #{upload_info.inspect}" )

              send_to_jabber( room, campfire_user_name, user['campfire_name'], 
                             "-- UPLOAD: #{upload_info['upload']['full_url']} -------------------------------" )
            end
          when "KickMessage", "LeaveMessage", "JoinMessage", "EnterMessage"
            if message['user_id'] != nil
              uname = room['broach_session'].get("users/#{message['user_id']}.json")['user']['id']
              fix_nicks( room, user )
            end
          else
            $log.info( "In while in room thread for #{room['campfire_room_name']}, unknown message type; message: #{message.inspect}" )
          end
        end
      rescue SocketError
        $log.info( "Networking problems in room thread for #{room['campfire_room_name']} with error: " )
        $log.info( e )
        exit
      rescue SystemExit
        $log.info( "Exit received in room thread for #{room['campfire_room_name']}" )
        exit
      rescue Exception => e
        $log.info( "detached from room #{room['campfire_room_name']} via error: " )
        $log.info( e )
      end
    end
  end
  return th
end

# tell jabber that we haven't heard of this user
def bad_user( from, to )
  $log.debug( "Sending bad user alert from #{from} to #{to}" )
  presence = Jabber::Presence.new.set_from(from).set_to(to).set_type(:error)
  presence.add_element( Jabber::MUC::XMUC.new() )
  presence.add_element(
    Jabber::ErrorResponse.new( "not-authorized", "The campfire server has never heard of you." ).set_type(:auth))
  jabber_send(presence)
end

def jabber_shutdown
  if $jabber_component && $jabber_component.is_connected?
    $users.each do |user|
      user['rooms'].each do |room|

        $log.info( "Shutting down room #{room['campfire_room_name']} for user #{user['jabber_id']}" )

        room_jid=nil
        if room.has_key?('room_jid')
          room_jid=room['room_jid']
        else
          room_jid="#{room['jabber_room_name']}@#{ArsonConfig::JabberComponentName}"
        end

        user_jid=nil
        if room.has_key?('user_jid')
          user_jid=room['user_jid']
        else
          user_jid=user['jabber_id']
        end

        send_presence( room_jid, user_jid, :unavailable, true, 'none', 'none', 'Campfire server shutting down.', [ '307' ] )
      end
    end
  end
end

def jabber_reset
  jabber_shutdown

  if $jabber_component && $jabber_component.is_connected?
    $jabber_component.close
  end

  #************************************************
  # Server Setup
  #************************************************
  $jabber_component = Jabber::Component::new(ArsonConfig::JabberComponentName)
  $jabber_component.connect(ArsonConfig::JabberComponentHost)
  $jabber_component.auth(ArsonConfig::JabberComponentSecret)

  #************************************************
  # Actual server code
  #************************************************
  setup_jabber_message_callback

  setup_jabber_presence_callback
end

def setup_jabber_presence_callback
  # Jabber Presence Handling
  $jabber_component.add_presence_callback do |pres|
    user_found=false
    from = pres.from.to_s
    to = pres.to.to_s
    type = pres.type.to_s

    # Here we walk through each of the users and see if this is a
    # message for one of them, and handle it appropriately (which
    # basically means either setting up handling for the campfire
    # room that goes with the jabber room they asked for, or doing
    # nothing.)
    $users.each do |user|
      if Regexp.new("^#{user['jabber_id']}/").match( from )
        user_found = true

        case type
        when 'unavailable'
          $log.info( "User #{from} has left the building." )

          user['rooms'].each do |room|
            $log.info( "Tearing down room #{room['campfire_room_name']} for user #{from}" )

            room['jabber_users'] = nil

            room['broach_session'] = nil

            if room.has_key?('maint_thread') and room['maint_thread'] != nil
              room['maint_thread'].kill
            end
            room['maint_thread'] = nil

            if room.has_key?('to_jabber_thread') and room['to_jabber_thread'] != nil
              room['to_jabber_thread'].kill
            end
            room['to_jabber_thread'] = nil
          end

          # Type is nil == available
        when ''
          # We've found the user; now find the room
          user['rooms'].each do |room|
            if room['jabber_room_name'].casecmp( to.gsub(/\@.*/, '') ) == 0
              # We've matched the room; do we already have it?
              if ! room.has_key?('broach_session') or room['broach_session'] == nil
                $log.debug( "Presence received for room #{to}, setting it up now." )
                # We don't; set it up
                Broach.settings = {
                  'account' => ArsonConfig::CampfireDomain.gsub(/\..*/, ''),
                  'token'   => user['campfire_token'],
                  'use_ssl' => true
                }

                # Now that broach is setup, get the user's campfire_id
                # if we don't already have it.
                if ! user.has_key?('campfire_id')
                  user['campfire_id'] = Broach.session.get("users/me.json")['user']['id']

                  user['campfire_name'] = Broach.session.get("users/me.json")['user']['name']
                end

                room['jabber_users'] = Hash.new

                room['campfire_room_id'] = Broach::Room.find_by_name( room['campfire_room_name'] ).id

                room['broach_session'] = Broach.session

                room['campfire_user_name'] = room['broach_session'].get("users/#{user['campfire_id']}")['user']['name']

                room['user_jid'] = from

                room['room_jid'] = to

                $log.debug( "Final room setup for user #{from}: results: #{YAML::dump(room)}" )

                fix_nicks( room, user )

                # Let the user know they're in
                send_presence( room['room_jid'],
                              room['user_jid'], nil, true,
                              'member', 'participant', nil, [ '100', '110', '210' ] )

                room['maint_thread'] = stay_in_campfire_room( room, user )

                room['to_jabber_thread'] = campfire_to_jabber( room, user )
              else
                $log.info( "Presence received for room #{to}, but it needs no setup." )

                fix_nicks( room, user )
                send_presence( room['room_jid'],
                              room['user_jid'], nil, true,
                              'member', 'participant', nil, [ '100', '110', '210' ] )
              end
            end
          end
          # Type is something else
        else
          $log.error( "Got a presence of type #{type}, which we don't handle; details: to: #{to}, from: #{from}" )
        end
      end
    end

    if ! user_found
      bad_user( to.gsub(/\/[^\/]*$/, ''), from )
    end
  end
end

#************************************************
# Jabber => Campfire Section
#
# Just listens for jabber messages and dispatches them to campfire
# if they seem relevant.
#************************************************
def setup_jabber_message_callback
  $jabber_component.add_message_callback do |message|
    begin
      # $log.debug( "In add_message_callback: #{YAML::dump(message)}" )

      to = message.to.to_s
      from = message.from.to_s
      body = message.body.to_s
      type = message.type.to_s
      $log.debug( "In add_message_callback: to: #{to}, from: #{from}, body: #{body}, type: #{type}" )

      if type == "groupchat"
        user_found=false
        room_found=false

        $users.each do |user|
          if Regexp.new("^#{user['jabber_id']}/").match( from )
            user_found = true

            $log.debug( "User jid #{user['jabber_id']} matches from #{from}" )

            # We've found the user; now find the room
            user['rooms'].each do |room|
              if room['jabber_room_name'].casecmp( to.gsub(/\@.*/, '') ) == 0
                room_found=true
                send_to_campfire( room, message.body )
              end
            end
          end
        end

        if ! user_found
          bad_user( to.gsub(/\/[^\/]*$/, ''), from )
        end

        if ! room_found
          $log.error( "Message sent to unknown jabber room #{to}" )
        end
      else
        $log.error( "Message of bad type '#{type}'; message details: to: #{to}, from: #{from}, body: #{body}" )
      end
    rescue SocketError
      $log.info( "Networking problems in jabber message callback with error: " )
      $log.info( e )
      exit
    rescue SystemExit
      $log.info( "Exit received in jabber message callback" )
      exit
    rescue Exception => e
      $log.info( "Error received in jabber message callback: " )
      $log.info( e )
    end
  end
end

#************************************************
# Server setup/running
#************************************************
Daemons.run_proc('arson',
                :dir_mode => :normal,
                :dir => ArsonConfig::LogDir,
                :monitor => true,
                :log_output => true ) do

  #************************************************
  # Configuration Loading
  #************************************************
  $log = Logger.new(STDERR)

  $log.level = ArsonConfig::LogLevel

  Jabber::debug = ArsonConfig::JabberDebug

  $users = Array.new

  ArsonConfig::Configs.each do |configfile|
    $users.push( YAML.load_file(configfile) )
  end

  $users.each do |user|
    user['rooms'].map! do |roomname|
      # Turn the room from a simple string into a hash
      room = Hash.new
      room['campfire_room_name'] = roomname

      # Fix bad jabber characters
      room['jabber_room_name'] = roomname.gsub(/\W+/,'-').gsub(/"\&'\/:<>@/,'')

      if room['campfire_room_name'] != room['jabber_room_name']
        $log.info( "Room name #{room['campfire_room_name']} not acceptable for Jabber, so the room name there is #{room['jabber_room_name']}" )
      end

      room
    end
  end

  $log.debug( "Config loaded: Users: #{YAML::dump($users)}" )

  #************************************************
  # Drop all the virtual users when we exit
  #************************************************
  at_exit do
    jabber_shutdown
  end

  jabber_reset

  #************************************************
  # Hang until signal
  #************************************************
  Thread.stop
end
