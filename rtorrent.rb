require 'rubygems'
require 'UPnP'
require 'thread'
require 'SCGIxml'

TRUST_ROUTER_LINK_SPEED = true

MIN_UP                  = 5
MIN_DOWN                = 50

MAX_CHANGE              = 5
NUM_OF_PROBE            = 5
INTERVAL                = 1

NETWORK_CONFIDENCY      = 0.8
UPNP_CONVERSION         = 1024*8
RTORRENT_CONVERSION     = 1024

CRIT_UP                 = 5
CRIT_DOWN               = 30

RTORRENT_INTERVAL       = 2

def get_average(v)
    a=0
    for i in 0..(NUM_OF_PROBE-2)
        a = a + v[i+1]-v[i]
    end
    return a/(NUM_OF_PROBE-1)
end


class UPnPDaemon

    def initialize()
        @upload = [0]*NUM_OF_PROBE
        @download = [0]*NUM_OF_PROBE
        @semaphore = Mutex.new

        @upnp = UPnP::UPnP.new
        @daemon = Thread.new do 
            while true do
              sent = @upnp.totalBytesSent().to_i
              recv = @upnp.totalBytesReceived().to_i
              @semaphore.synchronize {
                @upload = @upload[1,NUM_OF_PROBE]+[sent]
                @download = @download[1,NUM_OF_PROBE]+[recv]
              }
             sleep(1)
            end
        end
    end

    # values are in kbit/INTERVAL
    def get_upload()
        up = 0
        @semaphore.synchronize {
            up = get_average(@upload)
        }
        return up
    end

    # values are in kbit/INTERVAL
    def get_download()
        down = 0
        @semaphore.synchronize {
            down = get_average(@download)
        }
        return down
    end

    def linkBitrate()
        @upnp.maxLinkBitrates()
    end

    private
end

$d = UPnPDaemon.new

if TRUST_ROUTER_LINK_SPEED == true
    link_down, link_up = $d.linkBitrate()
    MAX_UP = (link_up.to_i/UPNP_CONVERSION)*NETWORK_CONFIDENCY
    MAX_DOWN = (link_down.to_i/UPNP_CONVERSION)*NETWORK_CONFIDENCY
else
    MAX_UP                  = 35
    MAX_DOWN                = 250
end

rtorrent = SCGIXMLClient.new(["/tmp/rtorrent.sock","/RPC2"])
rtorrent_up_a = [0]*NUM_OF_PROBE
rtorrent_down_a = [0]*NUM_OF_PROBE

while true do
    sleep(RTORRENT_INTERVAL)

    # query rtorrent for data
    rtorrent_max_up, rtorrent_max_down, list = rtorrent.multicall(["get_download_rate"],["get_upload_rate"],["download_list"]) 

    # get kB
    rtorrent_max_down /= RTORRENT_CONVERSION
    rtorrent_max_up   /= RTORRENT_CONVERSION
    
    # get total rates data
    request = []
    list.each do |d|
        request += ["d.get_up_rate",d] + ["d.get_down_rate",d] 
    end
    data = rtorrent.multicall(request)
    
    # calculate total rates
    rtorrent_up = 0
    rtorrent_down = 0
    for i in (0..list.length)
        rtorrent_up += data[i*2].to_i
        rtorrent_down += data[i*2+1].to_i
    end
    rtorrent_up_a = rtorrent_up_a[1,NUM_OF_PROBE]+[rtorrent_current_up]
    rtorrent_down_a =  rtorrent_down_a[1,NUM_OF_PROBE]+[rtorrent_current_down]
    rtorrent_up = get_average(rtorrent_up_a)     / RTORRENT_CONVERSION
    rtorrent_down = get_average(rtorrent_down_a) / RTORRENT_CONVERSION


    # get info from the router about used bandwidth
    router_up   = $d.get_upload   / UPNP_CONVERSION
    router_down = $d.get_download / UPNP_CONVERSION
    
    # get bandwidth of other programs
    other_up = router_up - rtorrent_up
    other_down = router_down - rtorrent_down

    ### ALGORITHM
    # VARIABLES:
    # router_up, router_down (avg over 5s)
    # rtorrent_max_up, rtorrent_max_down
    # rtorrent_up,rtorrent_down (avg over 5s)
    # other_up, other_down (avg over 5s)
    # store result in rtorrent_new_down, rtorrent_new_up
    
    rtorrent_new_down = router_down - other_down - CRIT_DOWN
    rtorrent_new_up   = router_up   - other_up   - CRIT_UP

    
    ### END
    diff = rtorrent_new_down - rtorrent_down
    if diff.abs > MAX_CHANGE
        if diff > 0 then
            rtorrent_new_down = rtorrent_down+MAX_CHANGE
        else
            rtorrent_new_down = rtorrent_down-MAX_CHANGE
        end
    end
    diff = rtorrent_new_up - rtorrent_up
    if diff.abs > MAX_CHANGE
        if diff > 0 then
            rtorrent_new_up = rtorrent_up+MAX_CHANGE
        else
            rtorrent_new_up = rtorrent_up-MAX_CHANGE
        end
    end

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
   
    # if needed apply the changes
    request = []
    if rtorrent_new_down == rtorrent_max_down
        request += ["set_download_rate","#{rtorrent_new_down*RTORRENT_CONVERSION}"]
    end
    if rtorrent_new_up == rtorrent_max_up
        request += ["set_upload_rate","#{rtorrent_new_up*RTORRENT_CONVERSION}"]
    end
    if request.length > 0 then
        rtorrent.multicall(request)
    end
end

