import Foundation

enum RekordboxFixtures {

    static let rekordbox6 = """
    <?xml version="1.0" encoding="UTF-8"?>

    <DJ_PLAYLISTS Version="1.0.0">
      <PRODUCT Name="rekordbox" Version="6.8.5" Company="AlphaTheta"/>
      <COLLECTION Entries="3">
        <TRACK TrackID="91234567" Name="Wavelength" Artist="Mara Lune" Composer="" Album="Night Pressings" Grouping="" Genre="Deep House" Kind="MP3 File" Size="11534336" TotalTime="287" DiscNumber="0" TrackNumber="3" Year="2025" AverageBpm="124.00" DateAdded="2026-03-14" BitRate="320" SampleRate="44100" Comments="Warm-up opener" PlayCount="12" Rating="204" Location="file://localhost/Users/dj/Music/DJ/Mara%20Lune%20-%20Wavelength.mp3" Remixer="" Tonality="8A" Label="" Mix="Original Mix" Colour="0xFF007F">
          <TEMPO Inizio="0.112" Bpm="124.00" Metro="4/4" Battito="1"/>
          <POSITION_MARK Name="" Type="0" Start="0.112" Num="-1"/>
          <POSITION_MARK Name="Drop" Type="0" Start="62.048" Num="0" Red="40" Green="226" Blue="20"/>
          <POSITION_MARK Name="Break" Type="0" Start="124.000" Num="1" Red="255" Green="140" Blue="0"/>
          <POSITION_MARK Name="" Type="4" Start="248.016" End="255.758" Num="-1"/>
          <POSITION_MARK Name="Load" Type="3" Start="0.112" Num="-1"/>
        </TRACK>
        <TRACK TrackID="91234568" Name="Late Night Drive (Original Mix)" Artist="Theo Moss feat. Juno Vale" Kind="WAV File" TotalTime="341" AverageBpm="122.00" Location="file://localhost/Users/dj/Music/DJ/Late%20Night%20Drive.wav" Tonality="Am" Colour="">
          <TEMPO Inizio="0.048" Bpm="122.00" Metro="4/4" Battito="1"/>
          <TEMPO Inizio="180.048" Bpm="124.00" Metro="4/4" Battito="1"/>
          <POSITION_MARK Name="Intro" Type="0" Start="0.048" Num="0" Red="48" Green="90" Blue="255"/>
        </TRACK>
        <TRACK TrackID="91234569" Name="Somebody Else &amp; Me" Artist="Low Sun" Kind="MP3 File" TotalTime="200" AverageBpm="128.00" Location="file://localhost/Users/dj/Music/DJ/Somebody%20Else.mp3" Tonality="" Colour=""/>
      </COLLECTION>
      <PLAYLISTS>
        <NODE Type="0" Name="ROOT" Count="2">
          <NODE Name="Warm-up" Type="1" KeyType="0" Entries="2">
            <TRACK Key="91234567"/>
            <TRACK Key="91234568"/>
          </NODE>
          <NODE Type="0" Name="Gigs" Count="1">
            <NODE Name="Friday" Type="1" KeyType="0" Entries="1">
              <TRACK Key="91234569"/>
            </NODE>
          </NODE>
        </NODE>
      </PLAYLISTS>
    </DJ_PLAYLISTS>
    """

    static let rekordbox7 = """
    <?xml version="1.0" encoding="UTF-8"?>

    <DJ_PLAYLISTS Version="1.0.0">
      <PRODUCT Name="rekordbox" Version="7.1.3" Company="AlphaTheta"/>
      <COLLECTION Entries="2">
        <TRACK TrackID="204001" Name="Orange Rooms" Artist="Soft Static" Kind="FLAC File" Size="40210432" TotalTime="402" AverageBpm="126.00" DateAdded="2026-10-02" BitRate="1411" SampleRate="44100" Comments="" PlayCount="3" Rating="0" Location="file://localhost/Volumes/Crate/Orange%20Rooms.flac" Tonality="Gm" Label="Copper Tapes" Mix="" Colour="0x25FDE9">
          <TEMPO Inizio="0.380" Bpm="126.00" Metro="4/4" Battito="3"/>
          <POSITION_MARK Name="Mix In" Type="0" Start="15.618" Num="-1"/>
          <POSITION_MARK Name="Drop" Type="0" Start="61.333" Num="0" Red="224" Green="100" Blue="27"/>
          <POSITION_MARK Name="Roll" Type="4" Start="122.285" End="124.190" Num="2" Red="0" Green="200" Blue="200"/>
          <POSITION_MARK Name="Outro loop" Type="4" Start="350.475" End="358.094" Num="-1"/>
          <POSITION_MARK Name="Mix Out" Type="0" Start="366.094" Num="-1"/>
        </TRACK>
        <TRACK TrackID="204002" Name="Paper Satellites" Artist="After Images" Kind="M4A File" TotalTime="254" AverageBpm="0.00" Location="file://localhost/Volumes/Crate/Paper%20Satellites.m4a" Tonality="" Colour=""/>
      </COLLECTION>
      <PLAYLISTS>
        <NODE Type="0" Name="ROOT" Count="1">
          <NODE Name="Peak" Type="1" KeyType="1" Entries="1">
            <TRACK Key="file://localhost/Volumes/Crate/Orange%20Rooms.flac"/>
          </NODE>
        </NODE>
      </PLAYLISTS>
    </DJ_PLAYLISTS>
    """
}
