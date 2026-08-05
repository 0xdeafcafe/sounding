import Foundation
@testable import SoundingTV

#if DEBUG

enum DiscoveryDecodeSelfTest {

    private enum Fixture {
    static let mixedSelectionsJSON = #"""
{"collection":[{"urn":"soundcloud:selections:buzzing","query_urn":"soundcloud:selections:8550d450788f4f338590391de8be80f6","title":"Artists to watch out for","description":null,"tracking_feature_name":"buzzing","last_updated":null,"style":null,"social_proof":null,"social_proof_users":null,"items":{"collection":[{"artwork_url":"https://i1.sndcdn.com/artworks-sbiHcsOIeeGCtwhO-M9QHbQ-large.jpg","created_at":"2025-03-20T15:39:38Z","duration":10661326,"id":1988906940,"kind":"playlist","last_modified":"2026-07-31T12:55:31Z","likes_count":9504,"managed_by_feeds":false,"permalink":"buzzing-mexico","permalink_url":"https://soundcloud.com/buzzing-playlists/sets/buzzing-mexico","public":true,"reposts_count":272,"secret_token":null,"sharing":"public","title":"Buzzing Mexico","track_count":50,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A1988906940","user_id":1356192489,"set_type":"","is_album":false,"published_at":"2025-03-20T19:34:46Z","release_date":null,"display_date":"2025-03-20T19:34:46Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-uBhncEiJEB6wuWPC-hwlXng-large.jpg","first_name":"Buzzing","followers_count":31888,"full_name":"Buzzing","id":1356192489,"kind":"user","last_modified":"2025-04-17T00:00:01Z","last_name":"","permalink":"buzzing-playlists","permalink_url":"https://soundcloud.com/buzzing-playlists","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A1356192489","urn":"soundcloud:users:1356192489","username":"New!","verified":true,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":false,"verified":true}}},{"artwork_url":"https://i1.sndcdn.com/artworks-cWAIo09Jt4R3rwGg-umbymw-large.jpg","created_at":"2024-02-22T13:56:01Z","duration":12556226,"id":1780168491,"kind":"playlist","last_modified":"2026-07-31T12:55:38Z","likes_count":58548,"managed_by_feeds":false,"permalink":"buzzing-electronic","permalink_url":"https://soundcloud.com/buzzing-playlists/sets/buzzing-electronic","public":true,"reposts_count":1193,"secret_token":null,"sharing":"public","title":"Buzzing Electronic","track_count":50,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A1780168491","user_id":1356192489,"set_type":"","is_album":false,"published_at":"2024-02-22T13:56:01Z","release_date":null,"display_date":"2024-02-22T13:56:01Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-uBhncEiJEB6wuWPC-hwlXng-large.jpg","first_name":"Buzzing","followers_count":31888,"full_name":"Buzzing","id":1356192489,"kind":"user","last_modified":"2025-04-17T00:00:01Z","last_name":"","permalink":"buzzing-playlists","permalink_url":"https://soundcloud.com/buzzing-playlists","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A1356192489","urn":"soundcloud:users:1356192489","username":"New!","verified":true,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":false,"verified":true}}}],"next_href":null,"query_urn":null},"kind":"selection","id":"soundcloud:selections:buzzing"},{"urn":"soundcloud:selections:promo-campaign-cp_newmusicshow_July31_CLONE","query_urn":"soundcloud:selections:8550d450788f4f338590391de8be80f6","title":"Your new weekly music show, with editor’s picks and commentary.","description":null,"tracking_feature_name":"promo-campaign-cp_newmusicshow_July31_CLONE","last_updated":null,"style":null,"social_proof":null,"social_proof_users":null,"items":{"collection":[{"artwork_url":"https://i1.sndcdn.com/artworks-2bqQdX1hgAgli3Gz-q0C1kw-large.jpg","created_at":"2026-07-22T13:02:20Z","duration":2173205,"id":2271795395,"kind":"playlist","last_modified":"2026-08-03T23:41:10Z","likes_count":44,"managed_by_feeds":false,"permalink":"the-upload","permalink_url":"https://soundcloud.com/soundcloud-stories/sets/the-upload","public":true,"reposts_count":8,"secret_token":null,"sharing":"public","title":"The Upload","track_count":17,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A2271795395","user_id":1284333535,"set_type":"","is_album":false,"published_at":"2026-07-31T11:09:49Z","release_date":null,"display_date":"2026-07-31T11:09:49Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-k2Z1gl8xsylwek0K-zB7CVg-large.jpg","first_name":"SoundCloud","followers_count":39716,"full_name":"SoundCloud Stories","id":1284333535,"kind":"user","last_modified":"2026-07-31T11:11:13Z","last_name":"Stories","permalink":"soundcloud-stories","permalink_url":"https://soundcloud.com/soundcloud-stories","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A1284333535","urn":"soundcloud:users:1284333535","username":"SoundCloud Stories","verified":true,"city":"NYC - LA - LDN","country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true}}},{"avatar_url":"https://i1.sndcdn.com/avatars-JNMBjX8Bajv6W4Tr-myQcWQ-large.jpg","first_name":"","followers_count":659,"full_name":"","id":1523771848,"kind":"user","last_modified":"2026-06-22T15:29:10Z","last_name":"","permalink":"moriah-mensah","permalink_url":"https://soundcloud.com/moriah-mensah","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A1523771848","urn":"soundcloud:users:1523771848","username":"Moriah Mensah","verified":true,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true}}],"next_href":null,"query_urn":null},"kind":"selection","id":"soundcloud:selections:promo-campaign-cp_newmusicshow_July31_CLONE"}],"next_href":null,"query_urn":"soundcloud:selections:8550d450788f4f338590391de8be80f6"}
"""#

    static let chartSelectionsJSON = #"""
{"collection":[{"urn":"soundcloud:selections:music-charts-us","query_urn":null,"title":"Music Charts US","description":null,"tracking_feature_name":null,"last_updated":null,"style":null,"social_proof":null,"social_proof_users":null,"items":{"collection":[{"artwork_url":"https://i1.sndcdn.com/artworks-6fXXwcQOhauWqPii-eZbIEg-large.jpg","created_at":"2023-11-01T08:43:25Z","duration":8653971,"id":1714689261,"kind":"playlist","last_modified":"2026-07-30T14:05:57Z","likes_count":2919,"managed_by_feeds":false,"permalink":"all-music-genres","permalink_url":"https://soundcloud.com/music-charts-us/sets/all-music-genres","public":true,"reposts_count":75,"secret_token":null,"sharing":"public","title":"All music genres","track_count":50,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A1714689261","user_id":1319568996,"set_type":"","is_album":false,"published_at":"2023-11-01T08:43:25Z","release_date":null,"display_date":"2023-11-01T08:43:25Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-UJJPPK1OkBLl9LzJ-wSZKdg-large.jpg","first_name":"","followers_count":10067,"full_name":"","id":1319568996,"kind":"user","last_modified":"2024-11-04T00:00:05Z","last_name":"","permalink":"music-charts-us","permalink_url":"https://soundcloud.com/music-charts-us","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A1319568996","urn":"soundcloud:users:1319568996","username":"Music Charts","verified":true,"city":"","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":false,"verified":true}}},{"artwork_url":"https://i1.sndcdn.com/artworks-l7fpJrMjSX0LejmR-XO7UuQ-large.jpg","created_at":"2023-10-28T13:35:11Z","duration":9011809,"id":1712717571,"kind":"playlist","last_modified":"2026-08-03T21:03:23Z","likes_count":11361,"managed_by_feeds":false,"permalink":"new-hot","permalink_url":"https://soundcloud.com/music-charts-us/sets/new-hot","public":true,"reposts_count":290,"secret_token":null,"sharing":"public","title":"New & Hot","track_count":50,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A1712717571","user_id":1319568996,"set_type":"","is_album":false,"published_at":"2023-10-28T13:35:11Z","release_date":null,"display_date":"2023-10-28T13:35:11Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-UJJPPK1OkBLl9LzJ-wSZKdg-large.jpg","first_name":"","followers_count":10067,"full_name":"","id":1319568996,"kind":"user","last_modified":"2024-11-04T00:00:05Z","last_name":"","permalink":"music-charts-us","permalink_url":"https://soundcloud.com/music-charts-us","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A1319568996","urn":"soundcloud:users:1319568996","username":"Music Charts","verified":true,"city":"","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":false,"verified":true}}}],"next_href":null,"query_urn":null},"kind":"selection","id":"soundcloud:selections:music-charts-us"}],"next_href":null,"query_urn":null}
"""#

    static let chartsJSON = #"""
{"genre":"soundcloud:genres:all-music","kind":"trending","last_updated":"2026-08-03T11:18:06Z","collection":[{"track":{"artwork_url":"https://i1.sndcdn.com/artworks-qQWb9gbszf8M-0-large.jpg","caption":null,"commentable":true,"comment_count":895,"created_at":"2026-05-14T02:26:46Z","description":"","downloadable":false,"download_count":0,"duration":170368,"full_duration":170322,"embeddable_by":"all","genre":"Hip Hop/Rap","has_downloads_left":false,"id":2320209185,"kind":"track","label_name":"Surf7","last_modified":"2026-07-02T22:47:05Z","license":"all-rights-reserved","likes_count":39966,"permalink":"surf7-goose-coat","permalink_url":"https://soundcloud.com/user-10135919/surf7-goose-coat","playback_count":1638249,"public":true,"publisher_metadata":{"id":2320209185,"urn":"soundcloud:tracks:2320209185","artist":"Surf7","album_title":"GOOSE COAT","contains_music":true,"upc_or_ean":"199384431040","isrc":"QZAKB2567875","explicit":true,"p_line":"℗ 2026 Surf7","p_line_for_display":"℗ 2026 Surf7","c_line":"© 2026 Surf7","c_line_for_display":"© 2026 Surf7","release_title":"GOOSE COAT"},"purchase_title":null,"purchase_url":null,"release_date":"2026-06-04T00:00:00Z","reposts_count":258,"secret_token":null,"sharing":"public","state":"finished","streamable":true,"tag_list":"","title":"GOOSE COAT","uri":"https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A2320209185","urn":"soundcloud:tracks:2320209185","user_id":335549515,"visuals":null,"waveform_url":"https://wave.sndcdn.com/clCTeRQUE5FC_m.json","display_date":"2026-06-04T00:00:00Z","media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/10b18013-f459-45bc-a89b-174d1afb85ac/stream/cbc-encrypted-hls","preset":"aac_160k","duration":170368,"snipped":false,"format":{"protocol":"cbc-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"sq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/10b18013-f459-45bc-a89b-174d1afb85ac/stream/ctr-encrypted-hls","preset":"aac_160k","duration":170368,"snipped":false,"format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"sq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/b0ca6c5c-3064-4c26-bc79-8c80dda4360f/stream/cbc-encrypted-hls","preset":"aac_96k","duration":170368,"snipped":false,"format":{"protocol":"cbc-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"lq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/b0ca6c5c-3064-4c26-bc79-8c80dda4360f/stream/ctr-encrypted-hls","preset":"aac_96k","duration":170368,"snipped":false,"format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"lq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/cd583b33-c9f1-4414-91d9-a5195f28a521/stream/cbc-encrypted-hls","preset":"abr_sq","duration":170368,"snipped":false,"format":{"protocol":"cbc-encrypted-hls","mime_type":"audio/mpegurl"},"quality":"sq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/cd583b33-c9f1-4414-91d9-a5195f28a521/stream/ctr-encrypted-hls","preset":"abr_sq","duration":170368,"snipped":false,"format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mpegurl"},"quality":"sq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/82326b90-b3d7-4871-8aea-e529342939ac/stream/hls","preset":"mp3_1_0","duration":170322,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mpeg"},"quality":"sq","is_legacy_transcoding":true},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2320209185/82326b90-b3d7-4871-8aea-e529342939ac/stream/progressive","preset":"mp3_1_0","duration":170322,"snipped":false,"format":{"protocol":"progressive","mime_type":"audio/mpeg"},"quality":"sq","is_legacy_transcoding":true}]},"station_urn":"soundcloud:system-playlists:track-stations:2320209185","station_permalink":"track-stations:2320209185","track_authorization":null,"monetization_model":"AD_SUPPORTED","policy":"MONETIZE","user":{"avatar_url":"https://i1.sndcdn.com/avatars-ZQ2a8rG0kF0PuirV-buivfA-large.jpg","first_name":"","followers_count":2945,"full_name":"","id":335549515,"kind":"user","last_modified":"2026-07-24T00:44:07Z","last_name":"","permalink":"user-10135919","permalink_url":"https://soundcloud.com/user-10135919","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A335549515","urn":"soundcloud:users:335549515","username":"Surf7","verified":false,"city":"","country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":false},"station_urn":"soundcloud:system-playlists:artist-stations:335549515","station_permalink":"artist-stations:335549515"}},"score":0.8447209462757054}],"query_urn":"soundcloud:charts:6fcc5a8d7b694c6fa66728da91b41365","next_href":"https://api-v2.soundcloud.com/charts?genre=soundcloud%3Agenres%3Aall-music&query_urn=soundcloud%3Acharts%3A6fcc5a8d7b694c6fa66728da91b41365&offset=20&kind=trending&limit=20"}
"""#

    static let systemPlaylistJSON = #"""
{"urn":"soundcloud:system-playlists:track-stations:2320209185","query_urn":null,"permalink":"track-stations:2320209185","permalink_url":"https://soundcloud.com/discover/sets/track-stations:2320209185","title":"GOOSE COAT","description":"Based on Surf7 - GOOSE COAT","short_title":"GOOSE COAT","short_description":"Track station","tracking_feature_name":"track-stations","playlist_type":"TRACK_STATION","last_updated":null,"artwork_url":"https://al.sndcdn.com/labs-e32a61ce-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBTVEFUSU9OCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoyMzIwMjA5MTg1Igp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MjM1MjIwNzIyNyIKdXJuczogInNvdW5kY2xvdWQ6dHJhY2tzOjE5Mjg0NTUyOTIiCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoyMzI4MjQwMTIyIgo%3D","calculated_artwork_url":"https://al.sndcdn.com/labs-e32a61ce-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBTVEFUSU9OCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoyMzIwMjA5MTg1Igp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MjM1MjIwNzIyNyIKdXJuczogInNvdW5kY2xvdWQ6dHJhY2tzOjE5Mjg0NTUyOTIiCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoyMzI4MjQwMTIyIgo%3D","likes_count":8,"seed":{"urn":"soundcloud:tracks:2320209185","permalink":"/user-10135919/surf7-goose-coat"},"tracks":[{"id":2320209185,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":2352207227,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":1928455292,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":2328240122,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":2309669483,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"}],"is_public":true,"made_for":null,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-69H9MhsAT5XDDltu-1X6yHw-large.jpg","first_name":"","followers_count":2378365,"full_name":"","id":193,"kind":"user","last_modified":"2026-04-14T22:08:08Z","last_name":"","permalink":"soundcloud","permalink_url":"https://soundcloud.com/soundcloud","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A193","urn":"soundcloud:users:193","username":"SoundCloud","verified":true,"city":"NY / LA","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:193","station_permalink":"artist-stations:193"},"kind":"system-playlist","id":"soundcloud:system-playlists:track-stations:2320209185"}
"""#

    static let relatedTracksJSON = #"""
{"collection":[{"artwork_url":"https://i1.sndcdn.com/artworks-000133187205-a2k299-large.jpg","caption":null,"commentable":true,"comment_count":2129,"created_at":"2015-10-19T03:53:05Z","description":"","downloadable":false,"download_count":0,"duration":199412,"full_duration":199437,"embeddable_by":"all","genre":"g herbo","has_downloads_left":false,"id":229041015,"kind":"track","label_name":null,"last_modified":"2022-07-12T23:52:44Z","license":"all-rights-reserved","likes_count":232616,"permalink":"write-your-name-prod-by-snapback","permalink_url":"https://soundcloud.com/gherbo/write-your-name-prod-by-snapback","playback_count":17304258,"public":true,"publisher_metadata":null,"purchase_title":null,"purchase_url":null,"release_date":null,"reposts_count":3942,"secret_token":null,"sharing":"public","state":"finished","streamable":true,"tag_list":"\"lil herb\" \"welcome to fazoland\" rap \"Hip Hop\" chicago","title":"Write Your Name (Prod. by Snapback)","uri":"https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A229041015","urn":"soundcloud:tracks:229041015","user_id":179398045,"visuals":null,"waveform_url":"https://wave.sndcdn.com/EgZoUsirjFjN_m.json","display_date":"2015-10-19T03:53:05Z","media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:229041015/10b7f482-0a2e-4b10-919d-5ce2141454e6/stream/hls","preset":"aac_160k","duration":199412,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"sq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:229041015/ba2e7ee7-2333-46f5-b0bf-68f66c803b11/stream/hls","preset":"aac_96k","duration":199412,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"lq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:229041015/60fa4372-dd19-4af1-b1f7-46b5fcd89fb9/stream/hls","preset":"abr_sq","duration":199412,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mpegurl"},"quality":"sq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:229041015/46bbad3b-c302-4168-b197-d612467bbde7/stream/hls","preset":"mp3_0_0","duration":199437,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mpeg"},"quality":"sq","is_legacy_transcoding":true},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:229041015/46bbad3b-c302-4168-b197-d612467bbde7/stream/progressive","preset":"mp3_0_0","duration":199437,"snipped":false,"format":{"protocol":"progressive","mime_type":"audio/mpeg"},"quality":"sq","is_legacy_transcoding":true}]},"station_urn":"soundcloud:system-playlists:track-stations:229041015","station_permalink":"track-stations:229041015","track_authorization":null,"monetization_model":"NOT_APPLICABLE","policy":"ALLOW","user":{"avatar_url":"https://i1.sndcdn.com/avatars-dmyFURydnMTFA6Zn-rzqJ0w-large.jpg","first_name":"G ","followers_count":625712,"full_name":"G  Herbo","id":179398045,"kind":"user","last_modified":"2026-06-22T21:22:31Z","last_name":"Herbo","permalink":"gherbo","permalink_url":"https://soundcloud.com/gherbo","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A179398045","urn":"soundcloud:users:179398045","username":"G Herbo","verified":true,"city":"Chicago","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:179398045","station_permalink":"artist-stations:179398045"}}],"query_urn":"soundcloud:similarsounds:87b3b4ee96d84b60aa124af405328e24","variant":"sim_sounds_v3"}
"""#

    static let authenticatedSelectionsJSON = #"""
{"collection":[{"urn":"soundcloud:selections:personalized-tracks:10000001","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","title":"More of what you like","description":null,"tracking_feature_name":"personalized-tracks","last_updated":null,"style":null,"social_proof":null,"social_proof_users":null,"items":{"collection":[{"urn":"soundcloud:system-playlists:personalized-tracks:10000001:2262770690","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","permalink":"personalized-tracks::listener:2262770690","permalink_url":"https://soundcloud.com/discover/sets/personalized-tracks::listener:2262770690","title":"Related tracks: Jordan George – Let The Music [TNTX040]","description":"Based on TNT - Jordan George – Let The Music [TNTX040]","short_title":"Jordan George – Let The Music [TNTX040]","short_description":"TNT, Homage, Pat de Ruiter, AMSTERDAM DANCE CAPITAL","tracking_feature_name":"personalized-tracks","playlist_type":"PLAYLIST","last_updated":null,"artwork_url":null,"calculated_artwork_url":"https://i1.sndcdn.com/artworks-Zswf9xyzSbhZ4mSk-ybVFcg-large.jpg","likes_count":0,"seed":{"urn":"soundcloud:tracks:2262770690","permalink":"/tnt_ofc/jordan-george-let-the-music-tntx040"},"tracks":[{"id":2262770690,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"},{"id":2256220469,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":2176954296,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"}],"is_public":false,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-69H9MhsAT5XDDltu-1X6yHw-large.jpg","first_name":"","followers_count":2378363,"full_name":"","id":193,"kind":"user","last_modified":"2026-04-14T22:08:08Z","last_name":"","permalink":"soundcloud","permalink_url":"https://soundcloud.com/soundcloud","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A193","urn":"soundcloud:users:193","username":"SoundCloud","verified":true,"city":"NY / LA","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:193","station_permalink":"artist-stations:193"},"kind":"system-playlist","id":"soundcloud:system-playlists:personalized-tracks:10000001:2262770690"},{"urn":"soundcloud:system-playlists:personalized-tracks:10000001:2151907044","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","permalink":"personalized-tracks::listener:2151907044","permalink_url":"https://soundcloud.com/discover/sets/personalized-tracks::listener:2151907044","title":"Related tracks: Elias Mazian & Tsepo - Wildeburg 2025","description":"Based on Wildeburg - Elias Mazian & Tsepo - Wildeburg 2025","short_title":"Elias Mazian & Tsepo - Wildeburg 2025","short_description":"Wildeburg, Sally C, Palms Trax, Ｇ ʰ o ˢｔａs ˢ","tracking_feature_name":"personalized-tracks","playlist_type":"PLAYLIST","last_updated":null,"artwork_url":null,"calculated_artwork_url":"https://i1.sndcdn.com/artworks-xrWjfwIrNKcl33zx-NUklEw-large.png","likes_count":0,"seed":{"urn":"soundcloud:tracks:2151907044","permalink":"/wildeburg/elias-mazian-tsepo-wildeburg-2025"},"tracks":[{"id":2151907044,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"},{"id":2287330571,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"},{"id":2208410882,"kind":"track","monetization_model":"NOT_APPLICABLE","policy":"ALLOW"}],"is_public":false,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-69H9MhsAT5XDDltu-1X6yHw-large.jpg","first_name":"","followers_count":2378363,"full_name":"","id":193,"kind":"user","last_modified":"2026-04-14T22:08:08Z","last_name":"","permalink":"soundcloud","permalink_url":"https://soundcloud.com/soundcloud","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A193","urn":"soundcloud:users:193","username":"SoundCloud","verified":true,"city":"NY / LA","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:193","station_permalink":"artist-stations:193"},"kind":"system-playlist","id":"soundcloud:system-playlists:personalized-tracks:10000001:2151907044"}],"next_href":null,"query_urn":null},"kind":"selection","id":"soundcloud:selections:personalized-tracks:10000001"},{"urn":"soundcloud:selections:recently-played:10000001","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","title":"Recently Played","description":null,"tracking_feature_name":"recently-played","last_updated":"58463-03-03T17:53:47Z","style":null,"social_proof":null,"social_proof_users":null,"items":{"collection":[{"avatar_url":"https://i1.sndcdn.com/avatars-o8zaaSMqcNYP7Vlf-iDlOXA-large.jpg","first_name":"Young","followers_count":42756,"full_name":"Young Marco","id":718982,"kind":"user","last_modified":"2024-03-07T06:25:21Z","last_name":"Marco","permalink":"youngmarco","permalink_url":"https://soundcloud.com/youngmarco","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A718982","urn":"soundcloud:users:718982","username":"Young Marco","verified":true,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true}},{"urn":"soundcloud:system-playlists:your-moods:10000001:1","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","permalink":"your-moods:10000001:1","permalink_url":"https://soundcloud.com/discover/sets/your-moods:10000001:1","title":"Your Mix 1","description":"El Columpio Asesino, KNTXT, Set About, Maddix, Luca Eck","short_title":null,"short_description":"El Columpio Asesino, KNTXT, Set About, Maddix, Luca Eck","tracking_feature_name":"your-moods","playlist_type":"PLAYLIST","last_updated":null,"artwork_url":"https://al.sndcdn.com/labs-91f8a35b-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBEQUlMWV9NSVhfUElMTF8xCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxMzY2Njk0MjkwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTM5NzkwNjY0NCIKdXJuczogInNvdW5kY2xvdWQ6dHJhY2tzOjE5MTkyMjk2MzIiCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxODM2NTY2OTEwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTUwNzEyMDQzNSIK","calculated_artwork_url":"https://al.sndcdn.com/labs-91f8a35b-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBEQUlMWV9NSVhfUElMTF8xCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxMzY2Njk0MjkwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTM5NzkwNjY0NCIKdXJuczogInNvdW5kY2xvdWQ6dHJhY2tzOjE5MTkyMjk2MzIiCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxODM2NTY2OTEwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTUwNzEyMDQzNSIK","likes_count":1,"seed":null,"tracks":[{"id":1366694290,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":1397906644,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":1919229632,"kind":"track","monetization_model":"NOT_APPLICABLE","policy":"ALLOW"}],"is_public":false,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-69H9MhsAT5XDDltu-1X6yHw-large.jpg","first_name":"","followers_count":2378363,"full_name":"","id":193,"kind":"user","last_modified":"2026-04-14T22:08:08Z","last_name":"","permalink":"soundcloud","permalink_url":"https://soundcloud.com/soundcloud","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A193","urn":"soundcloud:users:193","username":"SoundCloud","verified":true,"city":"NY / LA","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:193","station_permalink":"artist-stations:193"},"kind":"system-playlist","id":"soundcloud:system-playlists:your-moods:10000001:1"},{"urn":"soundcloud:system-playlists:your-moods:10000001:1","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","permalink":"your-moods:10000001:1","permalink_url":"https://soundcloud.com/discover/sets/your-moods:10000001:1","title":"Your Mix 1","description":"El Columpio Asesino, KNTXT, Set About, Maddix, Luca Eck","short_title":null,"short_description":"El Columpio Asesino, KNTXT, Set About, Maddix, Luca Eck","tracking_feature_name":"your-moods","playlist_type":"PLAYLIST","last_updated":null,"artwork_url":"https://al.sndcdn.com/labs-91f8a35b-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBEQUlMWV9NSVhfUElMTF8xCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxMzY2Njk0MjkwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTM5NzkwNjY0NCIKdXJuczogInNvdW5kY2xvdWQ6dHJhY2tzOjE5MTkyMjk2MzIiCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxODM2NTY2OTEwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTUwNzEyMDQzNSIK","calculated_artwork_url":"https://al.sndcdn.com/labs-91f8a35b-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBEQUlMWV9NSVhfUElMTF8xCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxMzY2Njk0MjkwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTM5NzkwNjY0NCIKdXJuczogInNvdW5kY2xvdWQ6dHJhY2tzOjE5MTkyMjk2MzIiCnVybnM6ICJzb3VuZGNsb3VkOnRyYWNrczoxODM2NTY2OTEwIgp1cm5zOiAic291bmRjbG91ZDp0cmFja3M6MTUwNzEyMDQzNSIK","likes_count":1,"seed":null,"tracks":[{"id":1366694290,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":1397906644,"kind":"track","monetization_model":"AD_SUPPORTED","policy":"MONETIZE"},{"id":1919229632,"kind":"track","monetization_model":"NOT_APPLICABLE","policy":"ALLOW"}],"is_public":false,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-69H9MhsAT5XDDltu-1X6yHw-large.jpg","first_name":"","followers_count":2378363,"full_name":"","id":193,"kind":"user","last_modified":"2026-04-14T22:08:08Z","last_name":"","permalink":"soundcloud","permalink_url":"https://soundcloud.com/soundcloud","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A193","urn":"soundcloud:users:193","username":"SoundCloud","verified":true,"city":"NY / LA","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:193","station_permalink":"artist-stations:193"},"kind":"system-playlist","id":"soundcloud:system-playlists:your-moods:10000001:1"},{"artwork_url":null,"created_at":"2026-02-10T08:34:06Z","duration":370181,"id":2189165825,"kind":"playlist","last_modified":"2026-02-10T09:44:32Z","likes_count":61,"managed_by_feeds":false,"permalink":"jordan-george-let-the-music","permalink_url":"https://soundcloud.com/jordangeorgedj/sets/jordan-george-let-the-music","public":true,"reposts_count":1,"secret_token":null,"sharing":"public","title":"Let The Music [TNTX040]","track_count":1,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A2189165825","user_id":208853168,"set_type":"","is_album":false,"published_at":"2026-02-10T08:34:06Z","release_date":null,"display_date":"2026-02-10T08:34:06Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-zKhckJropj3FyL9O-YQdc1g-large.jpg","first_name":"","followers_count":11079,"full_name":"","id":208853168,"kind":"user","last_modified":"2026-06-19T06:47:16Z","last_name":"","permalink":"jordangeorgedj","permalink_url":"https://soundcloud.com/jordangeorgedj","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A208853168","urn":"soundcloud:users:208853168","username":"Jordan George","verified":true,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true}}},{"artwork_url":null,"created_at":"2026-02-10T08:34:06Z","duration":370181,"id":2189165825,"kind":"playlist","last_modified":"2026-02-10T09:44:32Z","likes_count":61,"managed_by_feeds":false,"permalink":"jordan-george-let-the-music","permalink_url":"https://soundcloud.com/jordangeorgedj/sets/jordan-george-let-the-music","public":true,"reposts_count":1,"secret_token":null,"sharing":"public","title":"Let The Music [TNTX040]","track_count":1,"uri":"https://api.soundcloud.com/playlists/soundcloud%3Aplaylists%3A2189165825","user_id":208853168,"set_type":"","is_album":false,"published_at":"2026-02-10T08:34:06Z","release_date":null,"display_date":"2026-02-10T08:34:06Z","user":{"avatar_url":"https://i1.sndcdn.com/avatars-zKhckJropj3FyL9O-YQdc1g-large.jpg","first_name":"","followers_count":11079,"full_name":"","id":208853168,"kind":"user","last_modified":"2026-06-19T06:47:16Z","last_name":"","permalink":"jordangeorgedj","permalink_url":"https://soundcloud.com/jordangeorgedj","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A208853168","urn":"soundcloud:users:208853168","username":"Jordan George","verified":true,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true}}}],"next_href":null,"query_urn":null},"kind":"selection","id":"soundcloud:selections:recently-played:10000001"},{"urn":"soundcloud:selections:artist-stations","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","title":"Discover with Stations","description":null,"tracking_feature_name":"artist-stations","last_updated":null,"style":null,"social_proof":null,"social_proof_users":null,"items":{"collection":[{"urn":"soundcloud:system-playlists:artist-stations:202233458:2151907044","query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c","permalink":"artist-stations:202233458:2151907044","permalink_url":"https://soundcloud.com/discover/sets/artist-stations:202233458:2151907044","title":"Wildeburg","description":"Based on Wildeburg","short_title":"Wildeburg","short_description":"Artist station","tracking_feature_name":"artist-stations","playlist_type":"ARTIST_STATION","last_updated":null,"artwork_url":"https://al.sndcdn.com/labs-33beed77-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBTVEFUSU9OCnVybnM6ICJzb3VuZGNsb3VkOnVzZXJzOjIwMjIzMzQ1OCIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6MjA5NTc5OTA0Igp1cm5zOiAic291bmRjbG91ZDp1c2VyczoyMjc3OTI3OCIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6OTk1NDUzMTYiCnVybnM6ICJzb3VuZGNsb3VkOnVzZXJzOjU4NDE3NzgxMSIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6MTE1OTYxOTUwMyIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6NzgwMzYyMSIK","calculated_artwork_url":"https://al.sndcdn.com/labs-33beed77-0-t500x500.jpg?q=YXJ0d29ya190eXBlOiBTVEFUSU9OCnVybnM6ICJzb3VuZGNsb3VkOnVzZXJzOjIwMjIzMzQ1OCIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6MjA5NTc5OTA0Igp1cm5zOiAic291bmRjbG91ZDp1c2VyczoyMjc3OTI3OCIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6OTk1NDUzMTYiCnVybnM6ICJzb3VuZGNsb3VkOnVzZXJzOjU4NDE3NzgxMSIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6MTE1OTYxOTUwMyIKdXJuczogInNvdW5kY2xvdWQ6dXNlcnM6NzgwMzYyMSIK","likes_count":1,"seed":{"urn":"soundcloud:users:202233458","permalink":"/wildeburg"},"tracks":[{"id":2151907044,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"},{"id":1626952389,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"},{"id":2287330571,"kind":"track","monetization_model":"BLACKBOX","policy":"MONETIZE"}],"is_public":true,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-69H9MhsAT5XDDltu-1X6yHw-large.jpg","first_name":"","followers_count":2378363,"full_name":"","id":193,"kind":"user","last_modified":"2026-04-14T22:08:08Z","last_name":"","permalink":"soundcloud","permalink_url":"https://soundcloud.com/soundcloud","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A193","urn":"soundcloud:users:193","username":"SoundCloud","verified":true,"city":"NY / LA","country_code":"US","badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":true},"station_urn":"soundcloud:system-playlists:artist-stations:193","station_permalink":"artist-stations:193"},"kind":"system-playlist","id":"soundcloud:system-playlists:artist-stations:202233458:2151907044"}],"next_href":null,"query_urn":null},"kind":"selection","id":"soundcloud:selections:artist-stations"}],"next_href":null,"query_urn":"soundcloud:selections:1e5ed16df64e4f0789bf24267c36243c"}
"""#

    static let playHistoryJSON = #"""
{"collection":[{"played_at":1785611853632,"track_id":2148261924,"track":{"artwork_url":"https://i1.sndcdn.com/artworks-U9QBzh1IjciibtgL-sBHeGA-large.jpg","caption":null,"commentable":true,"comment_count":31,"created_at":"2025-08-05T13:19:58Z","description":"@essydj\nWildeburg Festival\nJuly 12, 2025 - Helling\nKraggenburg, Netherlands \nwww.wildeburg.nl","downloadable":false,"download_count":0,"duration":10717479,"full_duration":10717466,"embeddable_by":"all","genre":"","has_downloads_left":false,"id":2148261924,"kind":"track","label_name":"","last_modified":"2025-08-08T13:15:03Z","license":"all-rights-reserved","likes_count":402,"permalink":"essy-wildeburg-2025-helling-12072025","permalink_url":"https://soundcloud.com/wildeburg/essy-wildeburg-2025-helling-12072025","playback_count":8144,"public":true,"publisher_metadata":{"id":2148261924,"urn":"soundcloud:tracks:2148261924","artist":"Essy","explicit":false},"purchase_title":null,"purchase_url":null,"release_date":null,"reposts_count":8,"secret_token":null,"sharing":"public","state":"finished","streamable":true,"tag_list":"Electronic","title":"Essy - Wildeburg 2025","uri":"https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A2148261924","urn":"soundcloud:tracks:2148261924","user_id":202233458,"visuals":null,"waveform_url":"https://wave.sndcdn.com/nytOwrenYCR3_m.json","display_date":"2025-08-08T13:15:03Z","media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2148261924/c687d84c-6abf-4a04-8a59-2fd886ce109c/stream/hls","preset":"aac_256k","duration":10717479,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"hq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2148261924/b15db959-470a-4e19-a527-1de6c5d2848c/stream/hls","preset":"abr_hq","duration":10717479,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mpegurl"},"quality":"hq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2148261924/3eca2516-2dc7-4df4-99d0-a067c9a35f17/stream/hls","preset":"aac_1_0","duration":10717455,"snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"hq","is_legacy_transcoding":true}]},"station_urn":"soundcloud:system-playlists:track-stations:2148261924","station_permalink":"track-stations:2148261924","track_authorization":null,"monetization_model":"BLACKBOX","policy":"MONETIZE","user":{"avatar_url":"https://i1.sndcdn.com/avatars-9YSM17QF16xUo0Oa-7by4RA-large.jpg","first_name":"","followers_count":8238,"full_name":"","id":202233458,"kind":"user","last_modified":"2026-01-20T11:09:20Z","last_name":"","permalink":"wildeburg","permalink_url":"https://soundcloud.com/wildeburg","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A202233458","urn":"soundcloud:users:202233458","username":"Wildeburg","verified":false,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":true,"verified":false},"station_urn":"soundcloud:system-playlists:artist-stations:202233458","station_permalink":"artist-stations:202233458"}}},{"played_at":1785589145216,"track_id":2068736328,"track":{"artwork_url":"https://i1.sndcdn.com/artworks-xUkDq77hVvcT-0-large.jpg","caption":null,"commentable":true,"comment_count":0,"created_at":"2025-04-01T22:52:57Z","description":null,"downloadable":false,"download_count":0,"duration":244546,"full_duration":244532,"embeddable_by":"all","genre":"Electronic","has_downloads_left":false,"id":2068736328,"kind":"track","label_name":"V2 Records Benelux","last_modified":"2025-04-22T09:05:26Z","license":"all-rights-reserved","likes_count":19,"permalink":"oog-om-oog-feat-spinvis-elias","permalink_url":"https://soundcloud.com/junglebynight/oog-om-oog-feat-spinvis-elias","playback_count":493,"public":true,"publisher_metadata":{"id":2068736328,"urn":"soundcloud:tracks:2068736328","artist":"Jungle By Night","album_title":"Synergy Remixes","contains_music":true,"upc_or_ean":"8717931352741","isrc":"NLC242500039","explicit":false,"p_line":"(P) 2025 Jungle By Night & V2 Records","p_line_for_display":"℗ 2025 Jungle By Night & V2 Records","c_line":"(C) 2025 Jungle By Night & V2 Records","c_line_for_display":"© 2025 Jungle By Night & V2 Records","release_title":"Oog om Oog (feat. Spinvis) (Elias Mazian Remix)"},"purchase_title":null,"purchase_url":null,"release_date":"2025-04-18T00:00:00Z","reposts_count":3,"secret_token":null,"sharing":"public","state":"finished","streamable":true,"tag_list":"\"Indie Dance / Nu Disco\"","title":"Oog om Oog (feat. Spinvis) (Elias Mazian Remix)","uri":"https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A2068736328","urn":"soundcloud:tracks:2068736328","user_id":2550080,"visuals":null,"waveform_url":"https://wave.sndcdn.com/6CibNRBgFZd8_m.json","display_date":"2025-04-18T00:00:00Z","media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2068736328/de66c8fd-93ee-470f-81b9-4385aa5595d2/stream/cbc-encrypted-hls","preset":"aac_256k","duration":244546,"snipped":false,"format":{"protocol":"cbc-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"hq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2068736328/de66c8fd-93ee-470f-81b9-4385aa5595d2/stream/ctr-encrypted-hls","preset":"aac_256k","duration":244546,"snipped":false,"format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"hq","is_legacy_transcoding":false},{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2068736328/fe63955b-eb26-421c-a237-0096dcb97bce/stream/cbc-encrypted-hls","preset":"abr_hq","duration":244546,"snipped":false,"format":{"protocol":"cbc-encrypted-hls","mime_type":"audio/mpegurl"},"quality":"hq","is_legacy_transcoding":false}]},"station_urn":"soundcloud:system-playlists:track-stations:2068736328","station_permalink":"track-stations:2068736328","track_authorization":null,"monetization_model":"AD_SUPPORTED","policy":"MONETIZE","user":{"avatar_url":"https://i1.sndcdn.com/avatars-2h6UTJwscYoqzBfI-L7VQlg-large.jpg","first_name":"jungle","followers_count":3155,"full_name":"jungle by night","id":2550080,"kind":"user","last_modified":"2026-03-23T09:14:29Z","last_name":"by night","permalink":"junglebynight","permalink_url":"https://soundcloud.com/junglebynight","uri":"https://api.soundcloud.com/users/soundcloud%3Ausers%3A2550080","urn":"soundcloud:users:2550080","username":"Jungle By Night","verified":false,"city":null,"country_code":null,"badges":{"pro":false,"creator_mid_tier":false,"pro_unlimited":false,"verified":false},"station_urn":"soundcloud:system-playlists:artist-stations:2550080","station_permalink":"artist-stations:2550080"}}}],"next_href":"https://api-v2.soundcloud.com/me/play-history/tracks?offset=116501094&from=1785611853632&limit=25","query_urn":null}
"""#

    static let featuredTracksJSON = #"""
{"collection":[{"artwork_url":"https://i1.sndcdn.com/artworks-hkIDoX1ZAJuO-0-large.png","caption":null,"id":2372975567,"kind":"track","last_modified":"2026-08-02T21:36:55Z","permalink":"poured","permalink_url":"https://soundcloud.com/liluzivert/poured","public":true,"secret_token":null,"sharing":"public","title":"Poured","uri":"https://api.soundcloud.com/tracks/soundcloud%3Atracks%3A2372975567","urn":"soundcloud:tracks:2372975567","user_id":10494998,"full_duration":180369,"duration":180415,"display_date":"2026-07-31T00:00:00Z","media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:2372975567/ebe65ac5-1e8e-4f2f-a4e6-1a22d612e073/stream/cbc-encrypted-hls","preset":"aac_160k","duration":180415,"snipped":false,"format":{"protocol":"cbc-encrypted-hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""},"quality":"sq","is_legacy_transcoding":false}]},"station_urn":"soundcloud:system-playlists:track-stations:2372975567","station_permalink":"track-stations:2372975567","track_authorization":null,"monetization_model":"AD_SUPPORTED","policy":"MONETIZE"}],"kind":"trending","genre":"all-music","next_href":null,"query_urn":null}
"""#
    }

    private static func decoder() -> JSONDecoder {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder().decode(type, from: Data(json.utf8))
    }

    static func run() -> ModelDecodeSelfTestReport {
        var report = ModelDecodeSelfTestReport()
        testMixedSelections(&report)
        testHeterogeneousSelection(&report)
        testChartSelections(&report)
        testCharts(&report)
        testRelatedTracks(&report)
        testSystemPlaylist(&report)
        testSystemPlaylistIsNotAPlaylist(&report)
        testFeaturedTracksAreNotUsableTracks(&report)
        testSelectionItemRoundTrip(&report)
        testTrackCarriesStationURN(&report)
        testAuthenticatedSelectionsHoldStations(&report)
        testSystemPlaylistEncodesNumericTrackIDs(&report)
        testPlayHistoryPlayedAtIsEpochMillis(&report)
        testPlayHistoryRoundTripsAsNumbers(&report)
        testFailureReasonRedactsCredentials(&report)
        return report
    }

    private static func testMixedSelections(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Selection>.self, Fixture.mixedSelectionsJSON)
            guard page.collection.count == 2 else {
                report.failures.append("mixed-selections: expected 2 selections, got \(page.collection.count)")
                return
            }
            guard page.droppedCount == 0 else {
                report.failures.append("mixed-selections: dropped \(page.droppedCount) selection(s)")
                return
            }
            let first = page.collection[0]
            guard first.id == "soundcloud:selections:buzzing" else {
                report.failures.append("mixed-selections: expected urn id, got \"\(first.id)\"")
                return
            }
            guard first.title == "Artists to watch out for" else {
                report.failures.append("mixed-selections: server title lost — got \"\(first.title)\"")
                return
            }
            guard first.trackingFeatureName == "buzzing" else {
                report.failures.append("mixed-selections: tracking_feature_name lost")
                return
            }
            guard first.playlists.count == 2 else {
                report.failures.append("mixed-selections: expected 2 playlists, got \(first.playlists.count)")
                return
            }
            guard first.playlists.allSatisfy({ $0.tracks == nil }) else {
                report.failures.append("mixed-selections: expected unhydrated playlists (tracks == nil)")
                return
            }
            guard first.playlists.allSatisfy({ Int($0.id) != nil }) else {
                report.failures.append("mixed-selections: playlist ids should be numeric")
                return
            }
            report.lines.append("mixed-selections: 2 server-titled selections, "
                + "\"\(first.title)\" → \(first.playlists.count) unhydrated playlists")
        } catch {
            report.failures.append("mixed-selections: \(error)")
        }
    }

    private static func testHeterogeneousSelection(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Selection>.self, Fixture.mixedSelectionsJSON)
            guard page.collection.count == 2 else {
                report.failures.append("selection kinds: fixture shape changed")
                return
            }
            let promo = page.collection[1]
            guard promo.id.contains("promo-campaign") else {
                report.failures.append("selection kinds: expected the promo selection second")
                return
            }
            guard promo.items.collection.count == 2 else {
                report.failures.append("selection kinds: expected 2 items, got \(promo.items.collection.count)")
                return
            }
            guard promo.playlists.count == 1, promo.users.count == 1 else {
                report.failures.append("selection kinds: expected 1 playlist + 1 user, got "
                    + "\(promo.playlists.count) + \(promo.users.count)")
                return
            }
            report.lines.append("selection kinds: mixed playlist+user selection split cleanly")
        } catch {
            report.failures.append("selection kinds: \(error)")
        }
    }

    private static func testChartSelections(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Selection>.self, Fixture.chartSelectionsJSON)
            guard let first = page.collection.first else {
                report.failures.append("charts/selections: no selections decoded")
                return
            }
            guard first.title == "Music Charts US" else {
                report.failures.append("charts/selections: server title lost — got \"\(first.title)\"")
                return
            }
            guard first.playlists.count == 2 else {
                report.failures.append("charts/selections: expected 2 chart playlists, got \(first.playlists.count)")
                return
            }
            guard first.playlists[0].title == "All music genres" else {
                report.failures.append("charts/selections: chart playlist title lost")
                return
            }
            report.lines.append("charts/selections: \"\(first.title)\" → "
                + first.playlists.map(\.title).joined(separator: ", "))
        } catch {
            report.failures.append("charts/selections: \(error)")
        }
    }

    private static func testCharts(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<ChartEntry>.self, Fixture.chartsJSON)
            guard let entry = page.collection.first, page.droppedCount == 0 else {
                report.failures.append("charts: expected 1 undropped entry, got "
                    + "\(page.collection.count)/\(page.droppedCount) dropped")
                return
            }
            guard entry.score > 0 else {
                report.failures.append("charts: score not decoded (got \(entry.score))")
                return
            }
            guard entry.id == entry.track.id else {
                report.failures.append("charts: entry id should be the track id")
                return
            }
            guard entry.track.transcodings.count == 8 else {
                report.failures.append("charts: expected 8 transcodings, got \(entry.track.transcodings.count)")
                return
            }
            guard entry.track.streamURL != nil else {
                report.failures.append("charts: entitled chart track resolved no stream URL")
                return
            }
            guard entry.track.duration > 0 else {
                report.failures.append("charts: duration not resolved from transcodings")
                return
            }
            guard page.nextHref != nil else {
                report.failures.append("charts: next_href lost — pagination would stop at page 1")
                return
            }
            report.lines.append(String(format: "charts: {score %.3f, track} wrapper decoded, "
                + "\(entry.track.transcodings.count) transcodings, stream URL resolved", entry.score))
        } catch {
            report.failures.append("charts: \(error)")
        }
    }

    private static func testRelatedTracks(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Track>.self, Fixture.relatedTracksJSON)
            guard let track = page.collection.first, page.droppedCount == 0 else {
                report.failures.append("related: expected 1 undropped track, got "
                    + "\(page.collection.count)/\(page.droppedCount) dropped")
                return
            }
            guard track.streamURL != nil else {
                report.failures.append("related: entitled track resolved no stream URL")
                return
            }
            guard !track.user.username.isEmpty else {
                report.failures.append("related: nested user lost")
                return
            }
            report.lines.append("related: Page<Track> with \(track.transcodings.count) transcodings, "
                + "artist \"\(track.user.displayName)\"")
        } catch {
            report.failures.append("related: \(error)")
        }
    }

    private static func testSystemPlaylist(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let station = try decode(SystemPlaylist.self, Fixture.systemPlaylistJSON)
            guard station.id == "soundcloud:system-playlists:track-stations:2320209185" else {
                report.failures.append("system-playlist: urn id lost — got \"\(station.id)\"")
                return
            }
            guard station.stationKind == .track else {
                report.failures.append("system-playlist: expected a track station")
                return
            }
            guard station.description == "Based on Surf7 - GOOSE COAT" else {
                report.failures.append("system-playlist: server description lost")
                return
            }
            guard station.trackIDs.count == 5 else {
                report.failures.append("system-playlist: expected 5 manifest ids, got \(station.trackIDs.count)")
                return
            }
            guard station.trackIDs.first == "2320209185" else {
                report.failures.append("system-playlist: manifest order lost")
                return
            }
            guard station.seedURN == "soundcloud:tracks:2320209185" else {
                report.failures.append("system-playlist: seed urn lost")
                return
            }
            guard station.artworkURL != nil else {
                report.failures.append("system-playlist: calculated_artwork_url lost")
                return
            }
            guard station.user != nil else {
                report.failures.append("system-playlist: curator user lost")
                return
            }
            report.lines.append("system-playlist: \(station.trackIDs.count) stub ids, "
                + "\"\(station.description ?? "")\", kind \(station.stationKind)")
        } catch {
            report.failures.append("system-playlist: \(error)")
        }
    }

    private static func testSystemPlaylistIsNotAPlaylist(_ report: inout ModelDecodeSelfTestReport) {
        do {
            _ = try decode(Playlist.self, Fixture.systemPlaylistJSON)
            report.failures.append("system-playlist: decoded as Playlist — SystemPlaylist may be redundant, "
                + "or Playlist has silently relaxed its id/created_at requirements")
        } catch {
            report.lines.append("system-playlist: correctly refuses to decode as Playlist (string urn id)")
        }
    }

    private static func testFeaturedTracksAreNotUsableTracks(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Track>.self, Fixture.featuredTracksJSON)
            report.failures.append("featured_tracks: decoded \(page.collection.count) track(s) — "
                + "the endpoint now returns full tracks and getFeaturedTracks should be added")
        } catch {
            report.lines.append("featured_tracks: correctly refuses to decode as Page<Track> "
                + "(partial objects: no user, no created_at)")
        }
    }

    private static func testSelectionItemRoundTrip(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Selection>.self, Fixture.mixedSelectionsJSON)
            guard let promo = page.collection.last,
                  promo.items.collection.count == 2 else {
                report.failures.append("SelectionItem round-trip: fixture shape changed")
                return
            }
            let encoder = JSONEncoder()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            encoder.dateEncodingStrategy = .formatted(formatter)

            let authenticated = try decode(Page<Selection>.self, Fixture.authenticatedSelectionsJSON)
            guard authenticated.collection.count == 3 else {
                report.failures.append("SelectionItem round-trip: authenticated fixture shape changed")
                return
            }
            var sawStation = false
            for item in promo.items.collection + authenticated.collection[1].items.collection {
                let data = try encoder.encode(item)
                let back = try decoder().decode(SelectionItem.self, from: data)
                switch (item, back) {
                case (.playlist(let a), .playlist(let b)) where a.id == b.id: continue
                case (.user(let a), .user(let b)) where a.id == b.id: continue
                case (.systemPlaylist(let a), .systemPlaylist(let b)) where a.id == b.id:
                    guard a.trackIDs == b.trackIDs else {
                        report.failures.append("SelectionItem round-trip: station stub manifest changed "
                            + "across encode→decode (\(a.trackIDs.count) → \(b.trackIDs.count))")
                        return
                    }
                    sawStation = true
                default:
                    report.failures.append("SelectionItem round-trip: kind or id changed across encode→decode")
                    return
                }
            }
            guard sawStation else {
                report.failures.append("SelectionItem round-trip: no system-playlist item was exercised")
                return
            }
            report.lines.append("SelectionItem round-trip: playlist, user and system-playlist all survive "
                + "encode→decode with the kind discriminator and stub manifest intact")
        } catch {
            report.failures.append("SelectionItem round-trip: \(error)")
        }
    }

    private static func testTrackCarriesStationURN(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<ChartEntry>.self, Fixture.chartsJSON)
            guard let track = page.collection.first?.track else {
                report.failures.append("station urn: no chart track decoded")
                return
            }
            guard let urn = track.stationURN else {
                report.failures.append("station urn: station_urn not decoded off a real chart track")
                return
            }
            guard urn == "soundcloud:system-playlists:track-stations:\(track.id)" else {
                report.failures.append("station urn: unexpected form \"\(urn)\"")
                return
            }
            let encoder = JSONEncoder()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            encoder.dateEncodingStrategy = .formatted(formatter)
            let back = try decoder().decode(Track.self, from: try encoder.encode(track))
            guard back.stationURN == urn else {
                report.failures.append("station urn: lost on Track encode→decode (cache round-trip)")
                return
            }
            report.lines.append("station urn: read off the wire and survives a Track round-trip")
        } catch {
            report.failures.append("station urn: \(error)")
        }
    }

    private static func testAuthenticatedSelectionsHoldStations(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<Selection>.self, Fixture.authenticatedSelectionsJSON)
            guard page.collection.count == 3, page.droppedCount == 0 else {
                report.failures.append("authenticated selections: expected 3 undropped selections, got "
                    + "\(page.collection.count)/\(page.droppedCount) dropped")
                return
            }

            let personalised = page.collection[0]
            guard personalised.items.droppedCount == 0 else {
                report.failures.append("authenticated selections: dropped "
                    + "\(personalised.items.droppedCount) item(s) from a pure-station selection — "
                    + "SelectionItem no longer decodes system-playlist")
                return
            }
            guard personalised.stations.count == 2, personalised.playlists.isEmpty else {
                report.failures.append("authenticated selections: expected 2 stations + 0 playlists, got "
                    + "\(personalised.stations.count) + \(personalised.playlists.count)")
                return
            }

            let recent = page.collection[1]
            guard recent.stations.count == 2, recent.playlists.count == 2, recent.users.count == 1 else {
                report.failures.append("authenticated selections: mixed selection split wrong — "
                    + "\(recent.stations.count) stations, \(recent.playlists.count) playlists, "
                    + "\(recent.users.count) users")
                return
            }
            guard case .user = recent.items.collection[0] else {
                report.failures.append("authenticated selections: server item order lost — "
                    + "expected the user first in the mixed selection")
                return
            }
            guard recent.stations[0].id == recent.stations[1].id else {
                report.failures.append("authenticated selections: expected the repeated station "
                    + "the server sends once per play session")
                return
            }
            guard recent.stations[0].shortTitle == nil else {
                report.failures.append("authenticated selections: \"Your Mix\" stations are expected to "
                    + "carry no short_title — a card must fall back to `title`")
                return
            }

            let artistStations = page.collection[2]
            guard let artist = artistStations.stations.first, artist.stationKind == .artist else {
                report.failures.append("authenticated selections: expected an ARTIST_STATION in "
                    + "\"Discover with Stations\"")
                return
            }
            guard personalised.stations[0].stationKind == .other else {
                report.failures.append("authenticated selections: personalised stations are expected to "
                    + "report .other — filtering on stationKind would drop them")
                return
            }
            guard personalised.stations.allSatisfy({ $0.artworkURL != nil && !$0.trackIDs.isEmpty }) else {
                report.failures.append("authenticated selections: a station arrived with no artwork "
                    + "or no stub manifest")
                return
            }

            report.lines.append("authenticated selections: 3 selections, 0 dropped — "
                + "\(personalised.stations.count) pure stations, mixed shelf split "
                + "\(recent.stations.count)+\(recent.playlists.count)+\(recent.users.count) in server order")
        } catch {
            report.failures.append("authenticated selections: \(error)")
        }
    }

    private static func testSystemPlaylistEncodesNumericTrackIDs(_ report: inout ModelDecodeSelfTestReport) {
        func stubIDIsNumber(_ data: Data, _ label: String) -> Bool? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = root["tracks"] as? [[String: Any]],
                  let first = tracks.first, let raw = first["id"] else {
                report.failures.append("numeric stub ids: \(label) carries no tracks[0].id")
                return nil
            }
            if raw is NSNumber && !(raw is NSString) { return true }
            if raw is String { return false }
            report.failures.append("numeric stub ids: \(label) tracks[0].id is neither number nor string")
            return nil
        }

        do {
            let serverBytes = Data(Fixture.systemPlaylistJSON.utf8)
            guard let serverIsNumber = stubIDIsNumber(serverBytes, "the captured response") else { return }
            guard serverIsNumber else {
                report.failures.append("numeric stub ids: the captured api-v2 response sends stub ids as "
                    + "STRINGS — the encoder should follow the wire, not this test")
                return
            }

            let station = try decode(SystemPlaylist.self, Fixture.systemPlaylistJSON)
            guard station.trackIDs.first == "2320209185" else {
                report.failures.append("numeric stub ids: decode normalises to [String] — got "
                    + "\(station.trackIDs.first ?? "nil")")
                return
            }

            let encoded = try JSONEncoder().encode(station)

            guard let encodedIsNumber = stubIDIsNumber(encoded, "the encoded document") else { return }
            guard encodedIsNumber else {
                report.failures.append("numeric stub ids: encode wrote tracks[0].id as a STRING — the "
                    + "document no longer matches what SoundCloud sends")
                return
            }

            let text = String(decoding: encoded, as: UTF8.self)
            guard text.contains("\"id\":2320209185") else {
                report.failures.append("numeric stub ids: encoded bytes do not contain an unquoted "
                    + "\"id\":2320209185")
                return
            }
            guard !text.contains("\"id\":\"2320209185\"") else {
                report.failures.append("numeric stub ids: encoded bytes contain a quoted stub id")
                return
            }

            let back = try decoder().decode(SystemPlaylist.self, from: encoded)
            guard back.id == station.id, back.trackIDs == station.trackIDs else {
                report.failures.append("numeric stub ids: station did not survive encode→decode")
                return
            }

            report.lines.append("numeric stub ids: wire sends Int, model holds String, encoder emits "
                + "\"id\":2320209185 unquoted — \(station.trackIDs.count) ids round-tripped in order")
        } catch {
            report.failures.append("numeric stub ids: \(error)")
        }
    }

    private static func testPlayHistoryPlayedAtIsEpochMillis(_ report: inout ModelDecodeSelfTestReport) {
        do {
            do {
                _ = try decode(Page<PlayHistoryItemProbe>.self, Fixture.playHistoryJSON)
                report.failures.append("play history: a Date-typed `played_at` now decodes — the endpoint "
                    + "changed to ISO strings and PlayHistoryItem's millis path should be revisited")
                return
            } catch {
            }

            let page = try decode(Page<PlayHistoryItem>.self, Fixture.playHistoryJSON)
            guard page.collection.count == 2, page.droppedCount == 0 else {
                report.failures.append("play history: expected 2 undropped entries, got "
                    + "\(page.collection.count)/\(page.droppedCount) dropped")
                return
            }
            let first = page.collection[0]
            guard abs(first.playedAt.timeIntervalSince1970 - 1785611853.632) < 0.001 else {
                report.failures.append("play history: played_at converted wrong — "
                    + "\(first.playedAt.timeIntervalSince1970) vs 1785611853.632")
                return
            }
            guard first.trackID == "2148261924", first.trackID == first.track.id else {
                report.failures.append("play history: track_id not normalised to the Track's own id "
                    + "(\(first.trackID) vs \(first.track.id))")
                return
            }
            guard first.id == first.trackID else {
                report.failures.append("play history: id should be the track id so repeat plays "
                    + "deduplicate to the most recent")
                return
            }
            guard page.collection[0].playedAt > page.collection[1].playedAt else {
                report.failures.append("play history: expected most-recent-first ordering")
                return
            }
            guard !first.track.transcodings.isEmpty, first.track.streamURL != nil else {
                report.failures.append("play history: entitled track resolved no stream URL")
                return
            }
            guard first.track.user.username.isEmpty == false else {
                report.failures.append("play history: nested user lost — the track is not a full object")
                return
            }
            report.lines.append("play history: 2 entries, played_at read as epoch millis "
                + "(a Date-typed decode correctly throws), full Track with "
                + "\(first.track.transcodings.count) transcodings")
        } catch {
            report.failures.append("play history: \(error)")
        }
    }

    private struct PlayHistoryItemProbe: Codable {
        let playedAt: Date
        enum CodingKeys: String, CodingKey { case playedAt = "played_at" }
    }

    private static func testPlayHistoryRoundTripsAsNumbers(_ report: inout ModelDecodeSelfTestReport) {
        do {
            let page = try decode(Page<PlayHistoryItem>.self, Fixture.playHistoryJSON)
            guard let entry = page.collection.first else {
                report.failures.append("play history round-trip: fixture shape changed")
                return
            }
            let encoder = JSONEncoder()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            encoder.dateEncodingStrategy = .formatted(formatter)

            let data = try encoder.encode(entry)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                report.failures.append("play history round-trip: encoded document is not an object")
                return
            }
            guard let playedAt = root["played_at"], playedAt is NSNumber, !(playedAt is NSString) else {
                report.failures.append("play history round-trip: played_at was not written as a JSON "
                    + "number — the encoded document no longer matches the wire")
                return
            }
            guard let trackID = root["track_id"], trackID is NSNumber, !(trackID is NSString) else {
                report.failures.append("play history round-trip: track_id was not written as a JSON number")
                return
            }
            guard (playedAt as? NSNumber)?.int64Value == 1785611853632 else {
                report.failures.append("play history round-trip: millis changed across encode — got "
                    + "\(String(describing: playedAt))")
                return
            }
            let back = try decoder().decode(PlayHistoryItem.self, from: data)
            guard back.trackID == entry.trackID,
                  abs(back.playedAt.timeIntervalSince1970 - entry.playedAt.timeIntervalSince1970) < 0.001 else {
                report.failures.append("play history round-trip: entry did not survive encode→decode")
                return
            }
            report.lines.append("play history round-trip: played_at 1785611853632 and track_id both "
                + "re-encode as JSON numbers, not strings")
        } catch {
            report.failures.append("play history round-trip: \(error)")
        }
    }

    private static func testFailureReasonRedactsCredentials(_ report: inout ModelDecodeSelfTestReport) {
        let secret = "SYNTHETIC-NOT-A-REAL-TOKEN-0000"
        let cases: [(name: String, input: String, mustKeep: [String])] = [
            ("URLError shape",
             "Error Domain=NSURLErrorDomain Code=-1001 url=https://api-v2.soundcloud.com/me?oauth_token=\(secret)",
             ["api-v2.soundcloud.com/me", "-1001"]),
            ("token among other params",
             "failed https://api-v2.soundcloud.com/stream?limit=20&oauth_token=\(secret)&offset=0",
             ["/stream"]),
            ("two URLs in one message",
             "https://a.example/x?oauth_token=\(secret) then https://b.example/y?oauth_token=\(secret)",
             ["a.example/x", "b.example/y"]),
            ("newline after the URL",
             "Error Code=-1001\nurl=https://api-v2.soundcloud.com/me?oauth_token=\(secret)\n"
                + "userInfo={_kCFStreamErrorCodeKey=-2102}\nretrying",
             ["_kCFStreamErrorCodeKey", "retrying"]),
            ("URL in parentheses",
             "(https://api.example/q?oauth_token=\(secret)) failed", ["api.example/q", "failed"]),
            ("non-URL question mark untouched",
             "decode failed at tracks[0]?maybe", ["tracks[0]?maybe"])
        ]

        for c in cases {
            let redacted = DiscoverySourceFailure(id: "selftest", reason: c.input).reason
            guard !redacted.contains(secret) else {
                report.failures.append("credential redaction: token survived '\(c.name)'")
                return
            }
            for fragment in c.mustKeep where !redacted.contains(fragment) {
                report.failures.append("credential redaction: '\(c.name)' lost diagnostic '\(fragment)'")
                return
            }
        }
        report.lines.append("credential redaction: \(cases.count) error shapes redacted, "
            + "no token survived, diagnostics preserved")
    }
}

#endif
