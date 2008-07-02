require 'osx/cocoa'
require 'thread'
require 'lingr'
require 'growl'

class AppController < OSX::NSObject
  include OSX

  ib_outlets :preferenceController
  attr_reader :status_menu, :api

  GROWL_MESSAGE_TYPES = {
    :nickname => 'Nickname Changed',
    :join => 'Somebody Joined',
    :leave => 'Somebody Left',
    :message => 'Message Received'
  }

  def initialize
    @api = Lingr::Api.new "c26bb7e5c2004efda263a598d4b8d431"
    @api.verbosity = 0
    @api.timeout = 90
    @prefs = {}
    @observers = {}
    @sync = Queue.new
    @quiet = false
    @errors = 0
  end
  
  def awakeFromNib
    @growl = Growl::Notifier.alloc.init
    @growl.start("O'Radar", GROWL_MESSAGE_TYPES.collect {|k,v| v})
    init_status_bar

    @timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(30, self, "onHeartbeat:", nil, true)

    nc = NSWorkspace.sharedWorkspace.notificationCenter
    nc.addObserver_selector_name_object(self, :onHeartbeat, NSWorkspaceDidWakeNotification, nil)
  end

  def account_updated(params)
    performSelectorOnMainThread_withObject_waitUntilDone('onAccountUpdated:',
                                                         params, false)
  end

  def observed(type, observer=nil, params=nil)
    performSelectorOnMainThread_withObject_waitUntilDone('onObserved:', [type, observer, params], false)
    waitUntilDone
  end

  protected

  def start_over
    set_status_tooltip("Starting over...")
    @state = :connect

    rooms = []
    @observers.each {|id,r| rooms << r.roomid if r.is_a? Lingr::Room}
    rooms.each {|id| leave_room id}

    go
  end

  def go
    while true
      @state = :connect if @errors > 10

      case @state
      when :connect
        connect
      when :signin
        signin
      when :getinfo
        getinfo
      else
        return
      end
    end
  end

  def connect
    set_status_icon :normal, "Connecting..."
    sleep(10 * @errors)

    res = @api.session :create, { :client_type => 'automaton' }
    if res.ok?
      @errors = 0
      @state = :signin
      set_status_tooltip("Connected")
    else
      @errors += 1
      log "session/create: #{res}"
      set_status_icon :error, "Connection failure"
    end
  end

  def signin
    set_status_tooltip("Signing in...")
    sleep(10 * @errors)

    account = { :email => @prefs[:email], :password => @prefs[:password] }
    res = @api.auth :login, account
    if res.ok?
      @errors = 0
      @state = :getinfo
      set_status_tooltip("Signed in")
    else
      @errors += 1
      log "auth/login: #{res}"
      set_status_icon :error, "Sign in failure"
      if res.code == 105
        set_status_icon :error, "Invalid account"
        @state = :quiescent
      end
    end
  end

  def getinfo
    res = @api.user :get_info
    if res.ok?
      @errors = 0
      @state = :observe
      @nickname = res['default_nickname']
      set_status_tooltip("User Info receveid")

      res['monitored_rooms'].each {|r|
        log "entering: #{r['name']}"
        enter_room r['id']
      }

      u = Lingr::User.new(self)
      res = u.run
      if res.ok?
        @observers['user'] = u
      end
      update_tooltip_monitoring

    else
      @errors += 1
      log "user/get_info: #{res}"
      set_status_icon :error, "Failed to received User Info"
    end
  end

  def enter_room(id)
    r = Lingr::Room.new(self, id, @nickname)
    res = r.run
    if res.ok?
      if @observers.size == 1
        item = @status_bar.menu.itemWithTitle('No monitoring rooms')
        @status_bar.menu.removeItem item if item
      end

      @observers["room/#{id}"] = r

      item = @status_bar.
        menu.
        insertItemWithTitle_action_keyEquivalent_atIndex_(r.name,
                                                          "clickedOnMenu_Room:", "", 0)
      item.setTarget(self)
      item.setRepresentedObject r.url
      url = NSURL.URLWithString r.icon
      icon = NSImage.alloc.initByReferencingURL(url)
      if icon.TIFFRepresentation
        icon.setSize NSSize.new(18, 18)
        item.setImage(icon)        
      end
    end
    res.to_s
  end

  def leave_room(id)
    r = @observers["room/#{id}"]
    if r
      log "leaving #{id}"
      item = @status_bar.menu.itemWithTitle(r.name)
      log "#{r.roomid} / #{r.name} / #{item}"
      @status_bar.menu.removeItem item if item
      r.exit
      @observers.delete "room/#{id}"

      if @observers.size == 1
        @status_bar.
          menu.
          insertItemWithTitle_action_keyEquivalent_atIndex_("No monitoring rooms",
                                                            nil, "", 0)
      end
    end
  end

  def init_status_bar
    @status_menu = OSX::NSMenu.alloc.init
    @status_bar = NSStatusBar.systemStatusBar.statusItemWithLength(NSVariableStatusItemLength)
    set_status_icon :normal
    @status_bar.setHighlightMode true
    @status_bar.setMenu @status_menu
    @status_bar.setTarget_(self)
    init_menu
  end

  def init_menu
    add_menu_item "No monitoring rooms"
    add_menu_item
    add_menu_item "Quiet Mode", "clickedOnMenu_QuietMode:"
    add_menu_item
    add_menu_item "Preferences...", "clickedOnMenu_Preferences:"
    add_menu_item "About O'Radar", "clickedOnMenu_About:"
    add_menu_item "Open Lingr", "clickedOnMenu_OpenLingr:"
    add_menu_item
    add_menu_item "Quit O'Radar", "clickedOnMenu_Quit:"
  end

  def add_menu_item(title=nil, sel=nil)
    if title
      @status_bar.
        menu.
        addItemWithTitle_action_keyEquivalent_(title, sel, "")
    else
      @status_bar.menu.addItem(NSMenuItem.separatorItem)
    end
  end

  def set_status_icon(status, tooltip=nil)
    path = NSBundle.mainBundle.pathForResource_ofType("tray_#{status}", "png")
    @status_bar.setImage NSImage.alloc.initByReferencingFile(path)
    set_status_tooltip tooltip if tooltip
  end
  
  def set_status_tooltip(text)
    @status_bar.setToolTip text
    log text
  end


  def update_tooltip_monitoring
    item = @status_bar.menu.itemWithTitle('No monitoring rooms')
    @status_bar.menu.removeItem item if item

    case @observers.size
    when 2
      tooltip = "Monitoring 1 room"
    when 1
      tooltip = "No monitoring rooms"
      @status_bar.
        menu.
        insertItemWithTitle_action_keyEquivalent_atIndex_(tooltip,
                                                          nil, "", 0)
    else
      tooltip = "Monitoring #{@observers.size - 1} rooms"
    end

    set_status_icon :connected, tooltip
    log tooltip
  end

  def open_browser(url)
    NSWorkspace.sharedWorkspace.openURL NSURL.URLWithString(url)
  end

  def onHeartbeat(sender)
    log "state: #{@state}" if @prefs[:verbose]
    return unless @state == :observe

    dead = false
    @observers.each {|id,o|
      if o.status != 'observing'
        log "Unexpected: [#{id}] #{o.status}"
        dead = true
      end
    }
    start_over if dead
  end

  def onAccountUpdated(params)
    email = params['email']
    password = params['password']
    @prefs[:verbose] = params['verbose']

    return if @prefs[:email] == email and
      @prefs[:password] == password

    @prefs[:email] = email
    @prefs[:password] = password
    start_over
  end

  def onObserved(params)
    type = params[0]
    observer = params[1]
    event = params[2]

    log "event observed: #{type}"
    case type
    when 'user'
      @nickname = event['default_nickname'] if event['default_nickname']

      rooms = []
      @observers.each {|id,r|
        if r.is_a? Lingr::Room
          if !event['monitored_rooms'].find {|i| i['id'] == r.roomid}
            rooms << r.roomid
          end
        end
      }

      rooms.each {|id|
        leave_room id
      }

      event['monitored_rooms'].each {|r|
        unless @observers[ "room/#{r['id']}" ]
          enter_room r['id']
        end
      }

      update_tooltip_monitoring

    when 'room'
      unless @quiet
        event[:messages].each {|m|
          growl(observer.roomid, m)
        }
      end

    when 'error'
      log "========= ERROR ============="
      start_over
    end
    done
  end

  #
  # menu event handlers
  #
  def clickedOnMenu_Quit(sender)
    log "quitting..."
    @observers.each {|id,o|
      log "destroying observer: #{id}"
      o.exit
    }
    log "destroying session..."
    @api.session :destroy
    log "terminated successfully"
    NSApp.stop(nil)
  end
  
  def clickedOnMenu_Preferences(sender)
    @preferenceController.window.makeKeyAndOrderFront(self)
  end

  def clickedOnMenu_Room(sender)
    url =  sender.representedObject
    log "clickedOnMenu: #{url}"
    open_browser sender.representedObject
  end

  def clickedOnMenu_About(sender)
    NSApp.orderFrontStandardAboutPanelWithOptions(nil)
    if @prefs[:verbose]
      log "# of observers: #{@observers.size}"
      @observers.each {|id,o|
        log "[#{id}] #{o.status}"
      }
    end
  end

  def clickedOnMenu_OpenLingr(sender)
    open_browser "http://www.lingr.com/"
  end

  def clickedOnMenu_QuietMode(sender)
    @quiet = @quiet ? false : true
    @status_bar.
      menu.
      itemWithTitle("Quiet Mode").
      setState @quiet ? 1 : 0
  end

  #  m: occupant_id, timestamp, text, icon_url,
  #     nickname, client_type, type, id, source
  def growl(room, m)
    case m['type']
    when 'system:enter'
      type = GROWL_MESSAGE_TYPES[:join]
    when 'system:leave'
      type = GROWL_MESSAGE_TYPES[:leave]
    when 'system:nickname_change'
      type = GROWL_MESSAGE_TYPES[:nickname]
    else
      type = GROWL_MESSAGE_TYPES[:message]
      message = "#{m['nickname']}: #{m['text']}"
    end

    @growl.notify(type, room, message || m['text'])
  end

  def waitUntilDone
    @sync.pop # synchronize
  end

  def done
    @sync << :done
  end

  def log(s)
    OSX.NSLog(s)
  end
end

module Lingr

class Observer
  attr_reader :ticket, :counter

  def initialize(parent)
    @parent = parent
    @api = parent.api
    @thread = nil
    @errors = 0
  end

  def status
    return 'never' unless @thread
    case @thread.status
    when nil
      'dead'
    when false
      'done'
    when 'run', 'sleep'
      'observing'
    else
      @thread.status # aborting
    end
  end

  def run
    @ticket = nil
    @counter = nil

    res = start
    if res.ok?
      @thread = Thread.new { main } unless @thread
    end
    res
  end

  def exit
    log "observer exiting..."
    Thread.kill @thread if @thread
    stop if @ticket
    @ticket = nil
    @counter = nil
  end

  private

#  def start; end
#  def observe; end
#  def stop; end
#  def notify(res); end

  def main
    while true
      begin
        res = observe
        if res.ok?
          notify res
          @errors = 0
        else
          log "OBSERVE FAILED: errors(#{errors}) code(#{res.code})"
          @errors += 1
          if @errors > 10 then
            @parent.observed :error
          end
          sleep 10 * @errors
        end
      rescue Exception => e
        log "OBSERVE EXCEPTION: #{e.trace}"
      end
    end
  end

  def log(s, severity=0)
    OSX.NSLog(s)
  end
end

class User < Observer
  def start
    res = @api.user :start_observing
    @ticket = res[:ticket]
    @counter = res[:counter]
    res
  end

  def stop
    @api.user :stop_observing, { :ticket => @ticket }
  end

  def observe
    res = @api.user :observe, { :ticket => @ticket, :counter => @counter }
    @counter = res[:counter] if res[:counter]
    res
  end

  def notify(res)
    if res[:monitored_rooms]
      @parent.observed :user, self, res
    end
  end
end

class Room < Observer
  attr_reader :roomid, :name, :url, :icon, :occupants

  def initialize(parent, roomid, nickname=nil)
    super parent
    @roomid = roomid
    @nickname = nickname
  end
  
  def start
    params = { :id => @roomid, :idempotent => 'true' }
    params[:nickname] = @nickname if @nickname

    res = @api.room :enter, params
    if res.ok?
      @ticket = res[:ticket]
      @counter = res[:room]['counter']
      @name = res[:room]['name']
      @url =  res[:room]['url']
      @icon = res[:room]['icon_url']
      @occupants = res[:occupants]
    end
    res
  end

  def stop
    @api.room :exit, { :ticket => @ticket }
  end

  def observe
    res = @api.room :observe, { :ticket => @ticket, :counter => @counter }
    if res.ok?
      @counter = res[:counter] if res[:counter]
      @occupants = res[:occupants] if res[:occupants]
    end
    res
  end

  def notify(res)
    if res[:messages]
      @parent.observed :room, self, res
    end
  end
end

end
