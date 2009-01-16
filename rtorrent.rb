#! /usr/bin/ruby
require 'rubygems'

begin
    require 'UPnP'
rescue
    puts "Need gem mupnp"
end
require 'thread'
require 'SCGIxml'
require 'pp'

# Set debug to 2 to get a lot of info (every bandwidth change and router
# info). Set debug to 1 to get just the minimal information you need.
DEBUG = 0
DEBUG_LOGFILE="~/.rtorrent/controller.log"

# if set to false the program wan't trust the router reported speed.
# This is usefull if you are not connected with a DSL connection but for
# instance trough pppoe or other kind of connection that can't tell you
# the maximum available bandwidth.  If set to false you must fix
# LINE_UP_MAX and LINE_DOWN_MAX to the maximum theorical values of your
# line because these represents raw KByte/s you ocan send down the line,
# including any kind of nework overhead.
TRUST_ROUTER_LINK_SPEED = true
LINE_UP_MAX         = 0 # set these to the right values
LINE_DOWN_MAX       = 0 # 
# My modem reports 2464/352 kbps, so i used 308/44

# Where rtorrent socket is configured to be. I usually place it in my
# own home directory in rtorrent session directory you can change the
# location of the torrent in the .rtorrent.rc file with scgi_local =
# <absolute path>
RTORRENT_SOCKET = "~/.rtorrent/socket"

# Minimum values you will accept for a running rtorrent
MIN_UP              = 1
MIN_DOWN            = 1

# Change the speed at which the rates will vary
MAX_CHANGE_UP       = 2
MAX_CHANGE_DOWN     = 10

# These values just tells how much time upnp polls must be kept
# and how much time to sleep beetween 2 network
PROBE_INTERVAL      = 5
RTORRENT_INTERVAL   = 2

# These are conversion factors to onvert data reported from the router
# to KByte and from rtorrent to KByte
UPNP_CONVERSION     = 1024*8
RTORRENT_CONVERSION = 1024
RTORRENT_COEFFICENT = 0.9

DEBUG_FILE=File.open(DEBUG_LOGFILE, "a")
def log(x)
    DEBUG_FILE.puts(Time.now.to_s+"\t" + x)
    DEBUG_FILE.flush
end

def debug(x)
    if DEBUG >= 1 then
        log(x)
    end
end

def debug2(x)
    if DEBUG >= 2 then
        log(x)
    end
end
        
def get_average(v)
    a=0
    for i in 0..(v.length-2)
        a = a + v[i+1]-v[i]
    end
    return a/(v.length-1)
end


class UPnPDaemon

    def initialize()
        @upload    = [0]*PROBE_INTERVAL
        @download  = [0]*PROBE_INTERVAL
        @semaphore = Mutex.new
        @upnp = UPnP::UPnP.new
        @daemon = Thread.new do 
            while true do
                begin
                    @upnp = UPnP::UPnP.new if @upnp == nil
                    sent = @upnp.totalBytesSent().to_i
                    recv = @upnp.totalBytesReceived().to_i
                    @semaphore.synchronize {
                        @upload = @upload[1,PROBE_INTERVAL]+[sent]
                        @download = @download[1,PROBE_INTERVAL]+[recv]
                    }
                    sleep(1)
                rescue Exception => e
                    pp e
                    puts "Maybe some problem with the router. Suspend upnp for 1 minute."
                    sleep(60)
                    @upnp = nil
                end
            end
        end
    end

    # values are in kbit/INTERVAL
    def get_upload()
        up = 0
        @semaphore.synchronize { up = get_average(@upload) }
        return up
    end

    # values are in kbit/INTERVAL
    def get_download()
        down = 0
        @semaphore.synchronize { down = get_average(@download) }
        return down
    end

    def linkBitrate()
        @upnp.maxLinkBitrates()
    end
end

$d = UPnPDaemon.new

if TRUST_ROUTER_LINK_SPEED == true
    link_down, link_up = $d.linkBitrate()
    MAX_UP   = link_up.to_i   / UPNP_CONVERSION
    MAX_DOWN = link_down.to_i / UPNP_CONVERSION
else
    MAX_UP   = LINE_UP_MAX
    MAX_DOWN = LINE_DOWN_MAX
end

# These are the values everybody must care about. rtorrent will try to leave
# always CRIT_UP KByte/s in upload free and CRIT_DOWN KByte/s in
# download free.  And for free I mean always free. Do not increase
# upload too much, or you won't never get enough upload in ack packets
# to give more upload bandwidth to your downloads. These are just some
# values i am testing for my 384k/2M adsl line.
CRIT_UP             = 0.3  * MAX_UP
CRIT_DOWN           = 0.16 * MAX_DOWN

# This value is multiplied for the current download bandwidth and is
# subtracted to the upload bandwidth. The default is 0.01 (1% of
# download bandwidth). So if you are downloading at 200KB/s then the
# upload speed will be reduced by 2KB/s to allow for even faster
# transferts.
DOWNLOAD_COEFFICENT = 0.01

debug "MAX_UP = #{MAX_UP}"
debug "MAX_DOWN = #{MAX_DOWN}"
rtorrent        = SCGIXMLClient.new([RTORRENT_SOCKET,"/RPC2"])
rtorrent_up_a   = [0]*PROBE_INTERVAL
rtorrent_down_a = [0]*PROBE_INTERVAL

skip = 5
while true do
    sleep(RTORRENT_INTERVAL)
    rtorrent_max_down = 0
    rtorrent_max_up = 0
    list = []

    # query rtorrent for data
    begin
        rtorrent_max_down, rtorrent_max_up, list = rtorrent.multicall(["get_download_rate"],["get_upload_rate"],["download_list"])
    rescue Exception => e
        puts "Error while retriving data from rtorrent"
        pp e
        exit 1
    end

    # get kB
    rtorrent_max_down = rtorrent_max_down / RTORRENT_CONVERSION
    rtorrent_max_up   = rtorrent_max_up   / RTORRENT_CONVERSION
    
    # get info from the router about used bandwidth
    router_up   = $d.get_upload   / 1024
    router_down = $d.get_download / 1024

    if skip > 0 then
        debug "Skip: #{skip}"
        skip -= 1
        redo
    end

    debug2 "Router up: #{router_up}"
    debug2 "Router down: #{router_down}"

    ### ALGORITHM
    # VARIABLES:
    # router_up, router_down (avg over 5s)
    # rtorrent_max_up, rtorrent_max_down
    # store result in rtorrent_new_down, rtorrent_new_up
    
    rtorrent_new_up   = MAX_UP   - router_up   + rtorrent_max_up   - CRIT_UP  - router_down * DOWNLOAD_COEFFICENT
    rtorrent_new_down = MAX_DOWN - router_down + rtorrent_max_down - CRIT_DOWN

    debug2 "new_up #{rtorrent_new_up} = #{MAX_UP} - #{router_up} + #{rtorrent_max_up} - #{CRIT_UP}  - #{router_down} * #{DOWNLOAD_COEFFICENT}"
    debug2 "new_dw #{rtorrent_new_down} = #{MAX_DOWN} - #{router_down} + #{rtorrent_max_down} - #{CRIT_DOWN}"

    rtorrent_new_up   = rtorrent_new_up.to_i
    rtorrent_new_down = rtorrent_new_down.to_i

    # limit changes speeds
    if (rtorrent_new_up-rtorrent_max_up).abs > MAX_CHANGE_UP then
        if rtorrent_new_up > rtorrent_max_up then
            rtorrent_new_up = rtorrent_max_up + MAX_CHANGE_UP
        else
            rtorrent_new_up = rtorrent_max_up - MAX_CHANGE_UP
        end
    end
    if (rtorrent_new_down-rtorrent_max_down).abs > MAX_CHANGE_DOWN then
        if rtorrent_new_down > rtorrent_max_down then
            rtorrent_new_down = rtorrent_max_down + MAX_CHANGE_DOWN
        else
            rtorrent_new_down = rtorrent_max_down - MAX_CHANGE_DOWN
        end
    end

    # apply the limits
    #
    if rtorrent_new_down < MIN_DOWN and MIN_DOWN != 0
        rtorrent_new_down = MIN_DOWN
    elsif rtorrent_new_down > MAX_DOWN and MAX_DOWN != 0
        rtorrent_new_down = MAX_DOWN
    end
    if rtorrent_new_up < MIN_UP and MIN_UP != 0
        rtorrent_new_up = MIN_UP
    elsif rtorrent_new_up > MAX_UP and MAX_UP != 0
        rtorrent_new_up = MAX_UP
    end

    begin
        if rtorrent_new_down != rtorrent_max_down
            debug2 "fixing download to: #{rtorrent_new_down}"
            rtorrent.call("set_download_rate","#{rtorrent_new_down*RTORRENT_CONVERSION}")
        end
        if rtorrent_new_up != rtorrent_max_up
            debug2 "fixing upload to: #{rtorrent_new_up}"
            rtorrent.call("set_upload_rate","#{rtorrent_new_up*RTORRENT_CONVERSION}")
        end
    rescue Exception => e
        debug "Error while sending new limits to rtorrent"
        puts "Error while sending new limits to rtorrent"
        pp e
        exit 2
    end
end

