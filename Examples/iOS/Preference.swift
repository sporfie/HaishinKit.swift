struct Preference {
    static var defaultInstance = Preference()

//	var uri: String? = "rtmp://192.168.198.147/live"
	var uri: String? = "srt://192.168.198.147:10080/live/livestream?timeOffset=1"
    var streamName: String? = "livestream"
}
