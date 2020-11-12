struct Preference {
    static var defaultInstance = Preference()

    var uri: String? = "rtmp://192.168.198.212/encoder"
    var streamName: String? = "encoder1?timeOffset=0"
}
