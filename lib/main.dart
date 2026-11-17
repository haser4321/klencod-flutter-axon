import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

late AxonAudioHandler audioHandler;

final ValueNotifier<bool> axonDarkMode = ValueNotifier(true);
final ValueNotifier<Color> axonAccent =
    ValueNotifier(const Color(0xFF9B7BFF));

const Color axonBackground = Color(0xFF0B0D12);
const Color axonSurface = Color(0xFF171A23);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => AxonAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.axon.music.playback',
      androidNotificationChannelName: 'AXON Music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
    ),
  ) as AxonAudioHandler;

  runApp(const AxonApp());
}

// =====================================================
// SONG
// =====================================================

class AxonSong {
  final String path;
  final String title;

  AxonSong({
    required this.path,
    required this.title,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
      };

  factory AxonSong.fromJson(Map<String, dynamic> json) {
    return AxonSong(
      path: json['path'] as String,
      title: json['title'] as String,
    );
  }

  String get extension {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot + 1).toUpperCase();
  }
}

// =====================================================
// AUDIO HANDLER
// =====================================================

class AxonAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer player = AudioPlayer();

  List<AxonSong> songs = [];

  AudioServiceRepeatMode repeatMode =
      AudioServiceRepeatMode.none;

  bool shuffleEnabled = false;

  AxonAudioHandler() {
    player.playbackEventStream.listen((_) {
      _broadcastState();
    });

    player.currentIndexStream.listen((index) {
      if (index != null &&
          index >= 0 &&
          index < songs.length) {
        mediaItem.add(_mediaItem(index));
      }
      _broadcastState();
    });

    player.durationStream.listen((_) => _broadcastState());
    player.processingStateStream.listen((_) => _broadcastState());
  }

  MediaItem _mediaItem(int index) {
    final song = songs[index];

    return MediaItem(
      id: song.path,
      title: song.title,
      artist: 'AXON Music',
      album: 'Local Music',
      duration: player.duration,
    );
  }

  Future<void> setPlaylist(
    List<AxonSong> newSongs, {
    int initialIndex = 0,
    bool autoplay = false,
  }) async {
    songs = List<AxonSong>.from(newSongs);

    if (songs.isEmpty) {
      await player.stop();
      queue.add([]);
      mediaItem.add(null);
      _broadcastState();
      return;
    }

    final safeIndex = initialIndex.clamp(0, songs.length - 1);

    final items = songs.map((song) {
      return MediaItem(
        id: song.path,
        title: song.title,
        artist: 'AXON Music',
        album: 'Local Music',
      );
    }).toList();

    queue.add(items);

    await player.setAudioSources(
      songs.map((song) {
        return AudioSource.uri(
          Uri.file(song.path),
          tag: MediaItem(
            id: song.path,
            title: song.title,
            artist: 'AXON Music',
          ),
        );
      }).toList(),
      initialIndex: safeIndex,
      initialPosition: Duration.zero,
    );

    await player.setLoopMode(_loopMode);
    await player.setShuffleModeEnabled(shuffleEnabled);

    mediaItem.add(items[safeIndex]);
    _broadcastState();

    if (autoplay) {
      await play();
    }
  }

  LoopMode get _loopMode {
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        return LoopMode.one;
      case AudioServiceRepeatMode.all:
        return LoopMode.all;
      default:
        return LoopMode.off;
    }
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= songs.length) return;

    await player.seek(Duration.zero, index: index);
    await play();
  }

  void _broadcastState() {
    final playing = player.playing;

    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      if (playing)
        MediaControl.pause
      else
        MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.custom(
        name: 'axon_repeat',
        label: repeatMode == AudioServiceRepeatMode.one
            ? 'Repeat One'
            : repeatMode == AudioServiceRepeatMode.all
                ? 'Repeat All'
                : 'Repeat Off',
        androidIcon: 'drawable/ic_repeat',
      ),
    ];

    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[player.processingState]!,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: player.currentIndex,
        repeatMode: repeatMode,
        shuffleMode: shuffleEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (songs.isEmpty) return;
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    } else if (repeatMode == AudioServiceRepeatMode.all &&
        songs.isNotEmpty) {
      await playAt(0);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
    } else if (player.hasPrevious) {
      await player.seekToPrevious();
    } else if (repeatMode == AudioServiceRepeatMode.all &&
        songs.isNotEmpty) {
      await playAt(songs.length - 1);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async {
    repeatMode = mode;
    await player.setLoopMode(_loopMode);
    _broadcastState();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) async {
    shuffleEnabled = mode == AudioServiceShuffleMode.all;
    await player.setShuffleModeEnabled(shuffleEnabled);
    if (shuffleEnabled) {
      await player.shuffle();
    }
    _broadcastState();
  }

  Future<void> cycleRepeat() async {
    if (repeatMode == AudioServiceRepeatMode.none) {
      await setRepeatMode(AudioServiceRepeatMode.one);
    } else if (repeatMode == AudioServiceRepeatMode.one) {
      await setRepeatMode(AudioServiceRepeatMode.all);
    } else {
      await setRepeatMode(AudioServiceRepeatMode.none);
    }
  }

  Future<void> toggleShuffle() async {
    await setShuffleMode(
      shuffleEnabled
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all,
    );
  }

  @override
  Future<void> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == 'axon_repeat') {
      await cycleRepeat();
    }
  }
}

// =====================================================
// APPLICATION
// =====================================================

class AxonApp extends StatelessWidget {
  const AxonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: axonDarkMode,
      builder: (context, dark, _) {
        return ValueListenableBuilder<Color>(
          valueListenable: axonAccent,
          builder: (context, accent, _) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'AXON Music',
              theme: ThemeData(
                brightness:
                    dark ? Brightness.dark : Brightness.light,
                scaffoldBackgroundColor: dark
                    ? axonBackground
                    : const Color(0xFFF4F3F8),
                colorScheme: ColorScheme.fromSeed(
                  seedColor: accent,
                  brightness:
                      dark ? Brightness.dark : Brightness.light,
                ),
                useMaterial3: true,
              ),
              home: const AxonHome(),
            );
          },
        );
      },
    );
  }
}

// =====================================================
// HOME
// =====================================================

class AxonHome extends StatefulWidget {
  const AxonHome({super.key});

  @override
  State<AxonHome> createState() => _AxonHomeState();
}

class _AxonHomeState extends State<AxonHome> {
  List<AxonSong> songs = [];
  Set<String> favorites = {};
  Map<String, List<String>> playlists = {};

  List<String> history = [];

  bool loading = true;
  bool searchMode = false;
  String searchQuery = '';

  int selectedTab = 0;

  Timer? sleepTimer;
  int sleepMinutes = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    sleepTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    await Permission.notification.request();

    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getStringList('axon_songs') ?? [];
    final restored = <AxonSong>[];

    for (final path in saved) {
      if (await File(path).exists()) {
        restored.add(
          AxonSong(
            path: path,
            title: _getTitle(path),
          ),
        );
      }
    }

    songs = restored;
    favorites = (prefs.getStringList('axon_favorites') ?? []).toSet();
    history = prefs.getStringList('axon_history') ?? [];

    axonDarkMode.value = prefs.getBool('axon_dark') ?? true;

    final accentValue = prefs.getInt('axon_accent');
    if (accentValue != null) {
      axonAccent.value = Color(accentValue);
    }

    final savedPlaylists = prefs.getString('axon_playlists');
    if (savedPlaylists != null) {
      try {
        final decoded = jsonDecode(savedPlaylists) as Map;
        playlists = decoded.map(
          (key, value) => MapEntry(
            key.toString(),
            List<String>.from(value as List),
          ),
        );
      } catch (_) {
        playlists = {};
      }
    }

    await _saveLibrary();

    if (songs.isNotEmpty) {
      await audioHandler.setPlaylist(songs);
    }

    if (mounted) {
      setState(() => loading = false);
    }
  }

  String _getTitle(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'axon_songs',
      songs.map((song) => song.path).toList(),
    );
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'axon_favorites',
      favorites.toList(),
    );
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'axon_playlists',
      jsonEncode(playlists),
    );
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('axon_history', history);
  }

  Future<void> _addSongs(List<String> paths) async {
    int added = 0;

    for (final path in paths) {
      final lower = path.toLowerCase();

      if (!lower.endsWith('.mp3') &&
          !lower.endsWith('.m4a')) {
        continue;
      }

      if (!songs.any((song) => song.path == path)) {
        songs.add(
          AxonSong(
            path: path,
            title: _getTitle(path),
          ),
        );
        added++;
      }
    }

    await _saveLibrary();

    await audioHandler.setPlaylist(songs);

    if (mounted) {
      setState(() {});
      _showMessage(
        added == 0
            ? 'No new MP3 or M4A files found'
            : '$added songs added to AXON',
      );
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4a'],
        allowMultiple: true,
      );

      if (result == null) return;

      final paths = result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();

      await _addSongs(paths);
    } catch (e) {
      _showError('Unable to import music: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final directoryPath =
          await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Music Folder',
      );

      if (directoryPath == null) return;

      final directory = Directory(directoryPath);

      if (!await directory.exists()) {
        _showError('Folder cannot be accessed');
        return;
      }

      final paths = <String>[];

      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final path = entity.path.toLowerCase();

          if (path.endsWith('.mp3') || path.endsWith('.m4a')) {
            paths.add(entity.path);
          }
        }
      }

      await _addSongs(paths);
    } catch (e) {
      _showError('Unable to scan folder: $e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showError(String message) => _showMessage(message);

  Future<void> _playSong(int index) async {
    if (index < 0 || index >= songs.length) return;

    await audioHandler.playAt(index);

    final path = songs[index].path;
    history.remove(path);
    history.insert(0, path);

    if (history.length > 100) {
      history = history.take(100).toList();
    }

    await _saveHistory();

    if (mounted) setState(() {});
  }

  Future<void> _removeSong(int index) async {
    if (index < 0 || index >= songs.length) return;

    final currentIndex = audioHandler.player.currentIndex;
    final currentPath = currentIndex != null &&
            currentIndex >= 0 &&
            currentIndex < songs.length
        ? songs[currentIndex].path
        : null;

    songs.removeAt(index);

    await _saveLibrary();

    final newIndex = currentPath == null
        ? 0
        : songs.indexWhere((song) => song.path == currentPath);

    await audioHandler.setPlaylist(
      songs,
      initialIndex: newIndex < 0 ? 0 : newIndex,
    );

    if (mounted) setState(() {});
  }

  Future<void> _toggleFavorite(AxonSong song) async {
    if (favorites.contains(song.path)) {
      favorites.remove(song.path);
    } else {
      favorites.add(song.path);
    }

    await _saveFavorites();

    if (mounted) setState(() {});
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name == null) return;

    if (playlists.containsKey(name)) {
      _showMessage('This playlist already exists');
      return;
    }

    playlists[name] = [];
    await _savePlaylists();

    if (mounted) setState(() {});
  }

  Future<void> _addToPlaylist(AxonSong song) async {
    if (playlists.isEmpty) {
      await _createPlaylist();
    }

    if (!mounted || playlists.isEmpty) return;

    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist'),
        children: playlists.keys.map((name) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, name),
            child: Text(name),
          );
        }).toList(),
      ),
    );

    if (selected == null) return;

    final list = playlists[selected]!;
    if (!list.contains(song.path)) {
      list.add(song.path);
      await _savePlaylists();
    }

    if (mounted) {
      setState(() {});
      _showMessage('Added to $selected');
    }
  }

  Future<void> _startSleepTimer(int minutes) async {
    sleepTimer?.cancel();
    sleepMinutes = minutes;

    if (minutes <= 0) {
      if (mounted) setState(() {});
      _showMessage('Sleep timer cancelled');
      return;
    }

    sleepTimer = Timer(Duration(minutes: minutes), () async {
      await audioHandler.pause();
      if (mounted) {
        setState(() {
          sleepMinutes = 0;
        });
        _showMessage('Sleep timer finished');
      }
    });

    if (mounted) setState(() {});
    _showMessage('Music will stop after $minutes minutes');
  }

  List<AxonSong> get filteredSongs {
    if (searchQuery.trim().isEmpty) return songs;

    final query = searchQuery.toLowerCase();

    return songs.where((song) {
      return song.title.toLowerCase().contains(query);
    }).toList();
  }

  List<AxonSong> get favoriteSongs {
    return songs
        .where((song) => favorites.contains(song.path))
        .toList();
  }

  List<AxonSong> get historySongs {
    return history
        .map((path) {
          try {
            return songs.firstWhere((song) => song.path == path);
          } catch (_) {
            return null;
          }
        })
        .whereType<AxonSong>()
        .toList();
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '--:--';

    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);

    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: searchMode
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search music...',
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  setState(() => searchQuery = value);
                },
              )
            : Row(
                children: [
                  Icon(Icons.graphic_eq, color: axonAccent.value, size: 29),
                  const SizedBox(width: 10),
                  const Text(
                    'AXON',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                    ),
                  ),
                ],
              ),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                searchMode = !searchMode;
                if (!searchMode) searchQuery = '';
              });
            },
            icon: Icon(searchMode ? Icons.close : Icons.search),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'files') _pickFiles();
              if (value == 'folder') _pickFolder();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'files',
                child: Text('Add music files'),
              ),
              PopupMenuItem(
                value: 'folder',
                child: Text('Add music folder'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildPage()),
          _buildPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: (index) {
          setState(() => selectedTab = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: 'Favorites',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music),
            label: 'Playlists',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildPage() {
    switch (selectedTab) {
      case 0:
        return _buildHomePage();
      case 1:
        return _buildLibraryPage();
      case 2:
        return _buildSongCollection(
          favoriteSongs,
          'Your Favorites',
          Icons.favorite,
        );
      case 3:
        return _buildPlaylistsPage();
      case 4:
        return _buildSettingsPage();
      default:
        return _buildHomePage();
    }
  }

  Widget _buildHomePage() {
    final list = filteredSongs;

    return ListView(
      padding: const EdgeInsets.only(bottom: 15),
      children: [
        _buildHeader(),
        _sectionTitle('Recently Played'),
        if (historySongs.isEmpty)
          _emptyHint('Your listening history will appear here')
        else
          ...historySongs.take(4).map((song) {
            final index = songs.indexWhere(
              (item) => item.path == song.path,
            );
            return _buildSongTile(song, index);
          }),
        _sectionTitle('Your Music'),
        if (list.isEmpty)
          _buildEmpty()
        else
          ...list.asMap().entries.map((entry) {
            final index = songs.indexOf(entry.value);
            return _buildSongTile(entry.value, index);
          }),
      ],
    );
  }

  Widget _buildLibraryPage() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        _sectionTitle('Music Library'),
        _infoTile(
          Icons.music_note,
          'All Songs',
          '${songs.length} tracks',
          () => setState(() => selectedTab = 0),
        ),
        _infoTile(
          Icons.favorite,
          'Favorites',
          '${favoriteSongs.length} tracks',
          () => setState(() => selectedTab = 2),
        ),
        _infoTile(
          Icons.history,
          'Recently Played',
          '${historySongs.length} tracks',
          () => _showHistory(),
        ),
        _infoTile(
          Icons.folder_open,
          'Import Music Folder',
          'MP3 and M4A',
          _pickFolder,
        ),
        _infoTile(
          Icons.file_open,
          'Import Music Files',
          'Choose individual tracks',
          _pickFiles,
        ),
        _sectionTitle('All Tracks'),
        if (songs.isEmpty)
          _buildEmpty()
        else
          ...songs.asMap().entries.map(
                (entry) => _buildSongTile(
                  entry.value,
                  entry.key,
                ),
              ),
      ],
    );
  }

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return ListView(
          children: [
            const ListTile(
              title: Text('Recently Played'),
            ),
            ...historySongs.map((song) {
              final index = songs.indexOf(song);
              return ListTile(
                title: Text(song.title),
                onTap: () {
                  Navigator.pop(context);
                  _playSong(index);
                },
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildSongCollection(
    List<AxonSong> collection,
    String title,
    IconData icon,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        _sectionTitle(title),
        if (collection.isEmpty)
          _emptyHint('Nothing here yet')
        else
          ...collection.map((song) {
            final index = songs.indexOf(song);
            return _buildSongTile(song, index);
          }),
      ],
    );
  }

  Widget _buildPlaylistsPage() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Your Playlists',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _createPlaylist,
                icon: const Icon(Icons.add),
                label: const Text('New'),
              ),
            ],
          ),
        ),
        if (playlists.isEmpty)
          _emptyHint('Create your first playlist')
        else
          ...playlists.entries.map((entry) {
            return Card(
              margin: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 5,
              ),
              child: ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(entry.key),
                subtitle: Text('${entry.value.length} songs'),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'delete') {
                      playlists.remove(entry.key);
                      await _savePlaylists();
                      if (mounted) setState(() {});
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete playlist'),
                    ),
                  ],
                ),
                onTap: () => _openPlaylist(entry.key),
              ),
            );
          }),
      ],
    );
  }

  void _openPlaylist(String name) {
    final paths = playlists[name] ?? [];

    final playlistSongs = paths
        .map((path) {
          try {
            return songs.firstWhere((song) => song.path == path);
          } catch (_) {
            return null;
          }
        })
        .whereType<AxonSong>()
        .toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: ListView(
              children: [
                ListTile(
                  title: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text('${playlistSongs.length} songs'),
                  trailing: IconButton(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () async {
                      Navigator.pop(context);
                      await audioHandler.setPlaylist(
                        playlistSongs,
                        autoplay: true,
                      );
                    },
                  ),
                ),
                ...playlistSongs.map((song) {
                  final index = songs.indexOf(song);
                  return ListTile(
                    title: Text(song.title),
                    onTap: () {
                      Navigator.pop(context);
                      _playSong(index);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Appearance',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          title: const Text('Dark Mode'),
          subtitle: const Text('Use the dark AXON interface'),
          value: axonDarkMode.value,
          onChanged: (value) async {
            axonDarkMode.value = value;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('axon_dark', value);
          },
        ),
        const SizedBox(height: 12),
        const Text(
          'Accent Color',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          children: [
            const Color(0xFF9B7BFF),
            const Color(0xFF2196F3),
            const Color(0xFF00BFA5),
            const Color(0xFFFF9800),
            const Color(0xFFE91E63),
            const Color(0xFFEF5350),
          ].map((color) {
            return GestureDetector(
              onTap: () async {
                axonAccent.value = color;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('axon_accent', color.value);
              },
              child: CircleAvatar(
                backgroundColor: color,
                radius: 18,
                child: axonAccent.value.value == color.value
                    ? const Icon(Icons.check, color: Colors.white)
                    : null,
              ),
            );
          }).toList(),
        ),
        const Divider(height: 35),
        const Text(
          'Playback',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.repeat),
          title: const Text('Repeat Mode'),
          subtitle: Text(_repeatLabel(audioHandler.repeatMode)),
          onTap: () async {
            await audioHandler.cycleRepeat();
            if (mounted) setState(() {});
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.shuffle),
          title: const Text('Shuffle'),
          value: audioHandler.shuffleEnabled,
          onChanged: (value) async {
            await audioHandler.setShuffleMode(
              value
                  ? AudioServiceShuffleMode.all
                  : AudioServiceShuffleMode.none,
            );
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.bedtime_outlined),
          title: const Text('Sleep Timer'),
          subtitle: Text(
            sleepMinutes > 0
                ? 'Stops in $sleepMinutes minutes'
                : 'Not active',
          ),
          onTap: _showSleepTimer,
        ),
        if (sleepMinutes > 0)
          TextButton.icon(
            onPressed: () => _startSleepTimer(0),
            icon: const Icon(Icons.timer_off),
            label: const Text('Cancel Sleep Timer'),
          ),
        const Divider(height: 35),
        const Text(
          'About',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
        const ListTile(
          leading: Icon(Icons.graphic_eq),
          title: Text('AXON Music Player'),
          subtitle: Text('Version 1.0.0 • Offline Music Player'),
        ),
        const ListTile(
          leading: Icon(Icons.audio_file),
          title: Text('Supported Formats'),
          subtitle: Text('MP3 • M4A'),
        ),
      ],
    );
  }

  String _repeatLabel(AudioServiceRepeatMode mode) {
    if (mode == AudioServiceRepeatMode.one) return 'Repeat One';
    if (mode == AudioServiceRepeatMode.all) return 'Repeat All';
    return 'Repeat Off';
  }

  void _showSleepTimer() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'Sleep Timer',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              for (final minutes in [5, 10, 15, 20, 30, 45, 60, 90])
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('$minutes minutes'),
                  onTap: () {
                    Navigator.pop(context);
                    _startSleepTimer(minutes);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.timer_off),
                title: const Text('Cancel timer'),
                onTap: () {
                  Navigator.pop(context);
                  _startSleepTimer(0);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF29203F),
            Color(0xFF171A29),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR MUSIC',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white60,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 9),
                Text(
                  'Your sound.\nYour world.',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.headphones_rounded,
            size: 65,
            color: Color(0xFFB69CFF),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _emptyHint(String message) {
    return Padding(
      padding: const EdgeInsets.all(25),
      child: Center(
        child: Text(
          message,
          style: const TextStyle(color: Colors.white54),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _infoTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(icon, color: axonAccent.value),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.all(25),
      child: Column(
        children: [
          const Icon(
            Icons.music_off_rounded,
            size: 75,
            color: Colors.white24,
          ),
          const SizedBox(height: 18),
          const Text(
            'Your library is empty',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 9),
          const Text(
            'Add MP3 or M4A files to start listening.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose Music Folder'),
          ),
          TextButton(
            onPressed: _pickFiles,
            child: const Text('Choose Individual Songs'),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile(AxonSong song, int index) {
    if (index < 0) return const SizedBox.shrink();

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final isCurrent = snapshot.data?.id == song.path;
        final isFavorite = favorites.contains(song.path);

        return Container(
          margin: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: isCurrent
                ? const Color(0xFF252039)
                : Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: ListTile(
            onTap: () => _playSong(index),
            leading: Container(
              width: 45,
              height: 45,
              decoration: BoxDecoration(
                color: const Color(0xFF29223D),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isCurrent
                    ? Icons.equalizer_rounded
                    : Icons.music_note_rounded,
                color: const Color(0xFFB69CFF),
              ),
            ),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isCurrent
                    ? const Color(0xFFB69CFF)
                    : null,
              ),
            ),
            subtitle: Text(
              'AXON MUSIC • ${song.extension}',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 10,
              ),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'favorite') _toggleFavorite(song);
                if (value == 'playlist') _addToPlaylist(song);
                if (value == 'remove') _removeSong(index);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'favorite',
                  child: Text(
                    isFavorite
                        ? 'Remove from Favorites'
                        : 'Add to Favorites',
                  ),
                ),
                const PopupMenuItem(
                  value: 'playlist',
                  child: Text('Add to Playlist'),
                ),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from Library'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlayer() {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, mediaSnapshot) {
        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data;
            final isPlaying = state?.playing ?? false;
            final current = mediaSnapshot.data;
            final currentIndex = state?.queueIndex;

            final currentTitle =
                current?.title ?? 'Nothing Playing';

            return Container(
              padding: const EdgeInsets.fromLTRB(18, 15, 18, 20),
              decoration: const BoxDecoration(
                color: axonSurface,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'AXON MUSIC',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.graphic_eq,
                        color: isPlaying
                            ? axonAccent.value
                            : Colors.white24,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  StreamBuilder<Duration>(
                    stream: audioHandler.player.positionStream,
                    builder: (context, positionSnapshot) {
                      final position =
                          positionSnapshot.data ?? Duration.zero;

                      final duration =
                          audioHandler.player.duration ??
                              Duration.zero;

                      final max = duration.inMilliseconds > 0
                          ? duration.inMilliseconds.toDouble()
                          : 1.0;

                      final value = position.inMilliseconds
                          .toDouble()
                          .clamp(0.0, max);

                      return Column(
                        children: [
                          Slider(
                            value: value,
                            max: max,
                            activeColor: axonAccent.value,
                            inactiveColor: Colors.white12,
                            onChanged: duration.inMilliseconds == 0
                                ? null
                                : (v) {
                                    audioHandler.seek(
                                      Duration(
                                        milliseconds: v.toInt(),
                                      ),
                                    );
                                  },
                          ),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        tooltip: 'Repeat mode',
                        onPressed: () async {
                          await audioHandler.cycleRepeat();
                          if (mounted) setState(() {});
                        },
                        icon: Icon(
                          audioHandler.repeatMode ==
                                  AudioServiceRepeatMode.one
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          color: audioHandler.repeatMode ==
                                  AudioServiceRepeatMode.none
                              ? Colors.white38
                              : axonAccent.value,
                        ),
                      ),
                      IconButton(
                        onPressed: audioHandler.skipToPrevious,
                        icon: const Icon(
                          Icons.skip_previous_rounded,
                          size: 35,
                        ),
                      ),
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: axonAccent.value,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: songs.isEmpty
                              ? null
                              : () {
                                  if (isPlaying) {
                                    audioHandler.pause();
                                  } else if (currentIndex == null) {
                                    _playSong(0);
                                  } else {
                                    audioHandler.play();
                                  }
                                },
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 37,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: audioHandler.skipToNext,
                        icon: const Icon(
                          Icons.skip_next_rounded,
                          size: 35,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Shuffle',
                        onPressed: () async {
                          await audioHandler.toggleShuffle();
                          if (mounted) setState(() {});
                        },
                        icon: Icon(
                          Icons.shuffle_rounded,
                          color: audioHandler.shuffleEnabled
                              ? axonAccent.value
                              : Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}