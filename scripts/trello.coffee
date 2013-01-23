# Description:
#   Get notifications from trello for a given board.
#
# Dependencies:
#   "node-trello": "0.1.2"
#
# Configuration:
#   HUBOT_TRELLO_KEY - trello developer key
#   HUBOT_TRELLO_TOKEN - trello developer app token
#   HUBOT_TRELLO_BOARD_ID - trello board id
#   HUBOT_TRELLO_NOTIFY_ROOM - room to put notifications in
#
# Commands:
#   hubot trello check - check notifications
#   hubot trello ping - check connection
#
# Notes:
#   Currently cards can only be added to your default list/board although
#   this can be changed
#
#   Get app token by heading to https://trello.com/1/connect?
#       key=#{HUBOT_TRELLO_KEY}&name=<desired_app_name_here>&
#       response_type=token&scope=read,write&expiration=never
#
# Author:
#   n1k0

moment = require 'moment'
Trello = require 'node-trello'

check_interval_ms = process.env.HUBOT_TRELLO_INTERVAL ? 1000 * 60 * 5

checker = undefined

config =
  key: process.env.HUBOT_TRELLO_KEY
  token: process.env.HUBOT_TRELLO_TOKEN
  archive_days: process.env.HUBOT_TRELLO_ARCHIVE_DAYS || 15
  board_id: process.env.HUBOT_TRELLO_BOARD_ID
  notify_room: process.env.HUBOT_TRELLO_NOTIFY_ROOM

current_board = undefined

format = (str) ->
  str.replace(/\n/g, ' ').replace(/\s{2,}/g, ' ').trim()

filter_actions =
  changeCard: (notif) ->
    if 'listAfter' not of notif.data
      return
    format """#{notif.memberCreator.username} moved card `#{notif.data.card.name}`
              from `#{notif.data.listBefore.name}` to `#{notif.data.listAfter.name}`
              - #{cardUrl(notif.data.card)}"""
  commentCard: (notif) ->
    format """#{notif.memberCreator.username} commented on card `#{notif.data.card.name}`:
              #{notif.data.text} - #{cardUrl(notif.data.card)}"""
  createdCard: (notif) ->
    format """#{notif.memberCreator.username} created card `#{notif.data.card.name}`
              - #{cardUrl(notif.data.card)}"""

last_notif_id = undefined

cardUrl = (card) ->
  "https://trello.com/card/#{config.board_id}/#{card.idShort}"

connect = (onConnected, onError) ->
  console.error "missing HUBOT_TRELLO_KEY" if not config.key
  console.error "missing HUBOT_TRELLO_TOKEN" if not config.token
  console.error "missing HUBOT_TRELLO_BOARD_ID" if not config.board_id
  console.error "missing HUBOT_TRELLO_NOTIFY_ROOM" if not config.notify_room
  try
    t = new Trello config.key, config.token
  catch e
    console.error e
    return onError?(e)
  onConnected?(t)

dump = (data) ->
  console.log(JSON.stringify(data, null, 4))

get_boards = (cb, onError) ->
  connect (t) ->
    t.get "/1/organizations/scopyleft/boards", lists: 'open', filter: 'pinned', (err, boards) ->
      cb(err, boards)

get_notifs = (query, onComplete, onError) ->
  connect (t) ->
    t.get "/1/members/me/notifications", query, (err, data) ->
      if err
        return onError err
      if data and data[0] and data[0].id
        last_notif_id = data[0].id
      raw_notifs = (filter_actions[notif.type](notif) for notif in data)
      onComplete(notif for notif in raw_notifs when notif isnt undefined)
  , onError

init_checkers = (robot) ->
  overflow_checker = setInterval ->
    check_overflow (messages) ->
      for message in messages
        robot.messageRoom(config.notify_room, message)
  , check_interval_ms

  archive_checker = setInterval ->
    check_archive (messages) ->
      for message in messages
        robot.messageRoom(config.notify_room, message)
    , (err) ->
      console.error err
      msg.send "ERROR: " + err

parse_max_cards = (list) ->
  match = /\((\d+)\)$/.exec list.name
  if match
    max_cards = parseInt match[1], 10
  max_cards

board_info = (board, sep) ->
  sep ?= "\n -> "
  "Board: #{board.name}:#{sep}" + ("#{list.name}" for list in board.lists).join(sep)

archive_card = (card, onError) ->
  connect (t) ->
    t.put "/1/cards/#{card.id}/closed", value: "true", (err) ->
      if err then return onError?(err)
      console.info "archived #{card.name}"

check_archive = (cb, onError) ->
  get_boards (err, boards) ->
    if err then return onError?(err)
    boards.forEach (board) ->
      connect (t) ->
        t.get "/1/boards/#{board.id}/lists", cards: 'open', (err, lists) ->
          messages = []
          if err then return onError?(err)
          lists.forEach (list) ->
            if list.name != 'Terminé' then return
            list.cards.forEach (card) ->
              if /^Lisez-moi/.test(card.name) or card.closed then return
              expiry = moment(card.dateLastActivity).add('days', config.archive_days)
              if expiry < moment()
                archive_card card, (err) -> msg.send "Error: #{err}"
                messages.push format """card #{board.name} > #{list.name} > #{card.name}
                                        is more than #{config.archive_days} days old, archived
                                        #{card.shortUrl}"""
          cb(messages)

check_overflow = (board_id, cb, onError) ->
  get_boards (err, boards) ->
    if err then return onError?(err)
    boards.forEach (board) ->
      connect (t) ->
        t.get "/1/boards/#{board.id}/lists", cards: 'open', (err, lists) ->
          if err then return onError?(err)
          messages = []
          lists.forEach (list) ->
            max_cards = parse_max_cards(list)
            if list.cards.length > max_cards
              messages.push format """task overflow detected in \"#{list.name}\":
                                      #{list.cards.length}/#{max_cards}
                                      https://trello.com/board/#{board_id}"""
          cb(messages)

module.exports = (robot) ->
  robot.respond /trello boards$/i, (msg) ->
    connect (t) ->
      t.get "/1/organizations/scopyleft/boards", lists: 'open', (err, boards) ->
        if err then return onError?(err)
        msg.send board_info(board) for board in boards

  robot.respond /trello check overflow$/i, (msg) ->
    check_overflow (messages) ->
      msg.send(message) for message in messages
    , (err) ->
      console.error err
      msg.send "ERROR: " + err

  robot.respond /trello check archive$/i, (msg) ->
    check_archive (messages) ->
      msg.send(message) for message in messages
    , (err) ->
      console.error err
      msg.send "ERROR: " + err

  robot.respond /trello ping$/i, (msg) ->
    connect (t) ->
      msg.send "trello PONG"
    , (err) ->
      console.error err
      msg.send "ERROR: " + err

  robot.respond /trello recent$/i, (msg) ->
    query =
      filter: Object.keys(filter_actions)
      read_filter: 'unread'
      limit: 10
      since: last_notif_id
    get_notifs query, (notifs) ->
      msg.send(notif) for notif in notifs
    , (err) ->
      msg.send "Error: #{err}"

  init_checkers(robot)
