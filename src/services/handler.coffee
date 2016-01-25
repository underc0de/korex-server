parser = require "../utils/parser"
math = require "../utils/math"
logger = require "../utils/logger"
builder = require "../utils/builder"

User = require "../workers/user"
Chat = require "../workers/chat"
Commander = require "../workers/commander"
Profile = require "../workers/profile"

module.exports =
class Handler
  ###
  Section: Properties
  ###
  id: null
  socket: null
  user: {}
  chat: null
  logger: new logger(name: 'Handler')

  ###
  Section: Construction
  ###
  constructor: ->

  ###
  Section: Private
  ###
  read: (packet) ->
    @logger.log @logger.level.DEBUG, "-> #{packet}"

    packetTag = parser.getTagName(packet)

    # TODO: Kick when the user is spamming packets
    return if packetTag is null

    switch packetTag
      when "policy-file-request"
        @send "<?xml version=\"1.0\"?><!DOCTYPE cross-domain-policy SYSTEM \"http://www.adobe.com/xml/dtds/cross-domain-policy.dtd\"><cross-domain-policy><site-control permitted-cross-domain-policies=\"master-only\"/>#{global.Application.config.allow}</cross-domain-policy>\0"
      when "y"
        ###
        @spec <y r="1" v="0" u="USER_ID(int)" />
        ###
        loginKey = math.random(10000000, 99999999)
        loginShift = math.random(2, 5)
        loginTime = math.time()

        @send(builder.create('y')
          .append('i', loginKey)
          .append('c', loginTime)
          .append('p', '100_100_5_102')
          .compose())
      when "j2"
        ###
        Authenticate the client and join room
        @spec <j2 cb="0" l5="4288326302" l4="1400" l3="1267" l2="0" q="1" y="72226157" k="f13cee2b165605b4e400" k3="0" p="0" c="1" f="1" u="USER_ID(int)" d0="0" n="USERNAME(str)" a="91" h="" v="1" />
        ###
        User.process(@, packet).then(() =>
          delete global.Server.clients[@id]

          if global.Server.clients[@user.id]
            global.Server.clients[@user.id].send '<dup />'
            global.Server.clients[@user.id].dispose()

          global.Server.clients[@user.id] = @

          Chat.joinRoom.call(@)
        ).catch((err) => @logger.log @logger.level.ERROR, err, null)
      when "v"
        ###
        Authenticate through chat.swf
        @spec <v p="PASSWORD(str)" n="USERNAME(str)" />
        ###
        name = parser.getAttribute(packet, 'n')
        pw = parser.getAttribute(packet, 'p')

        User.login.call(@, name, pw)
      when "m"
        ###
        Send message
        @spec <m t="MESSAGE(str)" u="USER_ID(int)" />
        ###
        user = parser.getAttribute(packet, 'u')
        msg = parser.getAttribute(packet, 't')

        if msg.indexOf(Commander.identifier) is 0
          Commander.process(@, user, msg)
        else
          Chat.sendMessage.call(@, user, msg)
      when "c"
        ###
        Save user profile data
        @spec <c u="2" t="/b USER_ID(int),UNKNOWN(int),,USERNAME(str),AVATAR(str),HOME(str),0,0,0,0....." />
        ###
        type = parser.getAttribute(packet, 't')

        return if type is '/KEEPALIVE'
        
        @logger.log @logger.level.ERROR, "Unhandled user data update packet", null
      when "z"
        ###
        User profile
        @spec <z d="USER_ID_PROFILE(int)" u="USER_ID_ORIGIN(int)" t="TYPE(str)" />
        ###
        userProfileId = parser.getAttribute(packet, 'd')
        userProfile = global.Server.getClientById( userProfileId )?.user || null
        userOrigin = parser.getAttribute(packet, 'u')
        type = parser.getAttribute(packet, 't')

        if type is '/l' and userProfile != null
          username = if userProfile.username then "N=\"#{userProfile.username}\"" else ''
          status = "t=\"/a_Nofollow\"" # t=\"/a_on GROUP\"
          @send "<z b=\"1\" d=\"#{@user.id}\" u=\"#{userProfile.id}\" #{status} po=\"0\" #{userProfile.pStr} x=\"#{userProfile.xats||0}\" y=\"#{userProfile.days||0}\" q=\"3\" #{username} n=\"#{userProfile.nickname}\" a=\"#{userProfile.avatar}\" h=\"#{userProfile.url}\" v=\"2\" />"
        else if type is '/l'
          Profile.getById(userProfileId)
            .then((data) =>
              @logger.log @logger.level.ERROR, "Unhandled null userProfile", null
            )
            .catch((err) => @logger.log @logger.level.ERROR, err, 'Profile.coffee - getById()')
        else if type is '/a'
          return
        else
          @send "<z u=\"#{@user.id}\" t=\"#{type}\" s=\"#{parser.getAttribute(packet, 's')}\" d=\"#{userProfileId}\" />"
      else
        if packetTag.indexOf('w') is 0
          ###
          Room pools
          @spec <w v="ACTUAL_POOL(int) POOLS(int,int..)"  />
          ###
          @chat.onPool = packetTag.split('w')[1]
          Chat.joinRoom.call(@)
        else
          @logger.log @logger.level.ERROR, "Unrecognized packet by the server!", packetTag

  send: (packet) ->
    @socket.write "#{packet}\0"

    # Debug
    @logger.log @logger.level.DEBUG, "-> Sent: #{packet}"

  broadcast: (packet) ->
    console.log global.Server.rooms

    for client in global.Server.rooms[@user.chat] when client isnt @user.id
      console.log "Broadcasting to: #{global.Server.rooms[@user.chat]}"
      # NOTE: Maybe we can use the handler 'send' method
      global.Server.getClientById(client).socket.write "#{packet}\0"

    # Debug
    @logger.log @logger.level.DEBUG, "-> Broadcasted: #{packet}"

  setSocket: (socket) ->
    @socket = socket

    @socket.on 'data', (buffer) =>
      # Close the socket if it's a HTTP req
      if buffer.toString().indexOf('HTTP/') != -1
        @socket.end()
        return

      @read buffer.toString('binary')

  dispose: ->
    @socket.end()
    @socket.destroy()
