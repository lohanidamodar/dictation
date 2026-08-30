/// Win32 message state belongs to a thread, and a Dart isolate does not own
/// one.
///
/// `RegisterHotKey(null, …)` binds to the calling thread, and window messages
/// go to the thread that created the window. The Dart VM schedules an isolate
/// onto a thread from a pool and is free to move it between event-loop turns —
/// which it does, measurably: one run of this program registered its hotkey on
/// thread 17680 and was later pumping thread 38460. Everything stayed alive
/// and correct while draining a queue the messages never arrived in, so the
/// hotkey went dead and Windows pruned the tray icon whose owner had stopped
/// answering.
///
/// The fix is to give the windows a thread that cannot be rescheduled: an
/// isolate whose entry point enters a blocking `GetMessage` loop and never
/// returns to the Dart event loop. Nothing else may run there, so it owns only
/// the windows, the tray and the hotkey; the microphone, the recogniser and
/// the typing stay on the main isolate.
///
/// Talking to it goes the way Windows intends — `PostMessage`, which is
/// thread-safe by design. Commands therefore carry two integers rather than
/// objects, which is why the UI decides its own captions from a state code
/// instead of being handed strings.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';


/// What the overlay is showing. Sent as an integer, so the order is part of
/// the protocol.
enum UiOverlayState { hidden, listening, working, failed }

/// What the tray tooltip says.
enum UiStatus { loading, ready, listening, recognising, paused, failed }

/// Messages the main isolate posts to the UI thread.
abstract final class _Command {
  static const overlay = WM_APP + 10;
  static const status = WM_APP + 11;
  static const quit = WM_APP + 12;
}

/// The tray icon's own callback message.
const _trayCallback = WM_APP + 1;

/// Menu item ids, shared between the isolate that builds the menu and the
/// caller that acts on the choice.
abstract final class UiMenu {
  static const pause = 2;
  static const settings = 3;
  static const reload = 4;
  static const quit = 5;
}

/// Something that happened on the UI thread.
sealed class UiEvent {
  const UiEvent();
}

final class UiReady extends UiEvent {
  const UiReady();
}

/// The hotkey went down.
final class UiHotkeyPressed extends UiEvent {
  const UiHotkeyPressed();
}

/// …and came back up.
final class UiHotkeyReleased extends UiEvent {
  const UiHotkeyReleased();
}

final class UiMenuChosen extends UiEvent {
  const UiMenuChosen(this.id);
  final int id;
}

final class UiFailed extends UiEvent {
  const UiFailed(this.message);
  final String message;
}

/// The UI thread, as seen from the main isolate.
class UiHost {
  UiHost._(this._isolate, this._events, this._window, this._paused);

  final Isolate _isolate;
  final Stream<UiEvent> _events;

  /// The message-only window every command is posted to.
  int _window;

  bool _paused;

  Stream<UiEvent> get events => _events;

  /// Starts the UI thread and waits for its windows to exist.
  ///
  /// Throws [UiHostException] if the hotkey is already taken or a window
  /// cannot be created — both are the user's to fix, so they must surface
  /// rather than leaving a silently dead tray icon.
  static Future<UiHost> start({
    required int hotkeyModifiers,
    required int hotkeyKey,
    required String hotkeyLabel,
  }) async {
    final fromUi = ReceivePort();
    final events = StreamController<UiEvent>.broadcast();
    final ready = Completer<int>();

    final isolate = await Isolate.spawn(_uiIsolate, [
      fromUi.sendPort,
      hotkeyModifiers,
      hotkeyKey,
      hotkeyLabel,
    ]);

    fromUi.listen((Object? message) {
      if (message is! List || message.isEmpty) return;
      switch (message.first) {
        case 'ready':
          if (!ready.isCompleted) ready.complete(message[1] as int);
          events.add(const UiReady());
        case 'failed':
          if (!ready.isCompleted) {
            ready.completeError(UiHostException('${message[1]}'));
          }
          events.add(UiFailed('${message[1]}'));
        case 'pressed':
          events.add(const UiHotkeyPressed());
        case 'released':
          events.add(const UiHotkeyReleased());
        case 'menu':
          events.add(UiMenuChosen(message[1] as int));
      }
    });

    final window = await ready.future;
    return UiHost._(isolate, events.stream, window, false);
  }

  void _post(int message, int wParam, int lParam) {
    if (_window == 0) return;
    // PostMessage is safe across threads — it is the sanctioned way in.
    PostMessage(
      HWND(Pointer.fromAddress(_window)),
      message,
      WPARAM(wParam),
      LPARAM(lParam),
    );
  }

  /// Shows or hides the pill. [level] is 0..1.
  void showOverlay(UiOverlayState state, {double level = 0}) => _post(
        _Command.overlay,
        state.index,
        (level.clamp(0, 1) * 1000).round(),
      );

  void hideOverlay() => showOverlay(UiOverlayState.hidden);

  /// Updates the tooltip and the menu's first line.
  void setStatus(UiStatus status, {bool paused = false}) {
    _paused = paused;
    _post(_Command.status, status.index, paused ? 1 : 0);
  }

  bool get isPaused => _paused;

  Future<void> dispose() async {
    _post(_Command.quit, 0, 0);
    // A moment for the loop to unwind its windows and remove the tray icon,
    // then the isolate goes regardless.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _window = 0;
    _isolate.kill(priority: Isolate.immediate);
  }
}

class UiHostException implements Exception {
  const UiHostException(this.message);
  final String message;

  @override
  String toString() => message;
}

// ─── everything below runs on the UI thread ────────────────────────────────

const _hotkeyId = 1;

/// The id Windows actually gave the release timer.
///
/// `SetTimer` with a null window ignores the id it is handed and generates its
/// own, returning it. Comparing the arriving `WM_TIMER` against the id we
/// asked for therefore never matches, the release is never noticed, and the
/// app sits recording forever while ignoring every later press.
int _releaseTimer = 0;

late SendPort _toMain;
late String _hotkeyLabel;

int _messageWindow = 0;
int _overlayWindow = 0;
Pointer<NOTIFYICONDATA>? _trayData;

var _overlayState = UiOverlayState.hidden;
var _status = UiStatus.loading;
var _paused = false;
double _level = 0;
var _hotkeyDown = false;
var _running = true;

/// The UI thread.
///
/// Everything here happens on one OS thread that never returns to the Dart
/// event loop, so the VM cannot move it.
void _uiIsolate(List<Object?> args) {
  _toMain = args[0]! as SendPort;
  final modifiers = args[1]! as int;
  final key = args[2]! as int;
  _currentHotkeyKey = key;
  _hotkeyLabel = args[3]! as String;

  final messageProc =
      NativeCallable<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>
          .isolateLocal(_messageWindowProc, exceptionalReturn: 0);
  final overlayProc =
      NativeCallable<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>
          .isolateLocal(_overlayProc, exceptionalReturn: 0);

  try {
    _messageWindow = _createWindow(
      className: 'DictationHost',
      proc: messageProc,
      exStyle: 0,
      style: 0,
      parent: -3, // HWND_MESSAGE
      width: 0,
      height: 0,
    );
    _overlayWindow = _createWindow(
      className: 'DictationOverlay',
      proc: overlayProc,
      exStyle: WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      style: WS_POPUP,
      parent: 0,
      width: 280,
      height: 56,
    );
    _prepareOverlay();
    _addTrayIcon();

    final registered = RegisterHotKey(
      null,
      _hotkeyId,
      HOT_KEY_MODIFIERS(modifiers | MOD_NOREPEAT),
      VIRTUAL_KEY(key),
    );
    if (!registered.value) {
      _toMain.send([
        'failed',
        '$_hotkeyLabel is already taken by another program. '
            'Close whatever is using it, or choose a different combination.',
      ]);
      return;
    }
  } catch (e) {
    _toMain.send(['failed', '$e']);
    return;
  }

  _toMain.send(['ready', _messageWindow]);

  // The blocking loop. This is the whole point: it never yields, so this
  // isolate keeps the thread its windows and hotkey belong to.
  final msg = calloc<MSG>();
  while (_running) {
    // GetMessage returns false on WM_QUIT, which is how the loop ends.
    if (!GetMessage(msg, null, 0, 0).value) break;

    // A hotkey registered against no window, and a thread timer, both arrive
    // with no window — DispatchMessage would drop them.
    if (msg.ref.hwnd.address == 0) {
      _handleThreadMessage(msg.ref.message, msg.ref.wParam);
      continue;
    }
    TranslateMessage(msg);
    DispatchMessage(msg);
  }

  calloc.free(msg);
  UnregisterHotKey(null, _hotkeyId);
  _removeTrayIcon();
  messageProc.close();
  overlayProc.close();
}

void _handleThreadMessage(int message, int wParam) {
  switch (message) {
    case WM_HOTKEY:
      if (_hotkeyDown) return;
      _hotkeyDown = true;
      _toMain.send(const ['pressed']);
      // Windows reports the press but never the release, so the key is polled
      // from a timer — which wakes GetMessage, keeping the loop blocking.
      _releaseTimer = SetTimer(null, 0, 15, nullptr).value;

    case WM_TIMER:
      if (wParam != _releaseTimer || !_hotkeyDown) return;
      if (GetAsyncKeyState(_currentHotkeyKey) & 0x8000 != 0) return;
      KillTimer(null, _releaseTimer);
      _releaseTimer = 0;
      _hotkeyDown = false;
      _toMain.send(const ['released']);
  }
}

int _currentHotkeyKey = 0;

int _createWindow({
  required String className,
  required NativeCallable<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)> proc,
  required int exStyle,
  required int style,
  required int parent,
  required int width,
  required int height,
}) {
  final namePtr = className.toNativeUtf16();
  final instance = HINSTANCE(GetModuleHandle(null).value);

  final wc = calloc<WNDCLASS>()
    ..ref.lpfnWndProc = proc.nativeFunction.cast()
    ..ref.hInstance = instance
    ..ref.lpszClassName = PWSTR(namePtr);
  RegisterClass(wc);
  calloc.free(wc);

  final created = CreateWindowEx(
    WINDOW_EX_STYLE(exStyle),
    PCWSTR(namePtr),
    PCWSTR(namePtr),
    WINDOW_STYLE(style),
    0,
    0,
    width,
    height,
    HWND(Pointer.fromAddress(parent)),
    null,
    instance,
    nullptr,
  ).value;

  if (created.address == 0) {
    throw UiHostException('Could not create the "$className" window.');
  }
  return created.address;
}

int _messageWindowProc(int hwnd, int message, int wParam, int lParam) {
  switch (message) {
    case _Command.overlay:
      _overlayState = UiOverlayState.values[wParam];
      _level = lParam / 1000.0;
      _applyOverlay();
      return 0;

    case _Command.status:
      _status = UiStatus.values[wParam];
      _paused = lParam == 1;
      _applyStatus();
      return 0;

    case _Command.quit:
      _running = false;
      // GetMessage returns 0 on WM_QUIT, which ends the loop.
      PostQuitMessage(0);
      return 0;

    case _trayCallback:
      final event = lParam & 0xFFFF;
      if (event == WM_RBUTTONUP || event == WM_LBUTTONUP) {
        _showMenu(hwnd);
      }
      return 0;

    case WM_COMMAND:
      _toMain.send(['menu', wParam & 0xFFFF]);
      return 0;
  }
  return DefWindowProc(
    HWND(Pointer.fromAddress(hwnd)),
    message,
    WPARAM(wParam),
    LPARAM(lParam),
  );
}

// ─── icon ──────────────────────────────────────────────────────────────────

int _idleIcon = 0;
int _activeIcon = 0;

/// Draws a microphone into a 32x32 icon, in code.
///
/// No .ico file: the app compiles to a single exe, and an icon that lives
/// beside it is one more thing to lose. Two are made — a quiet one and a red
/// one for while the microphone is open — because the tray is where someone
/// glances to check whether it is listening.
int _makeIcon({required bool active}) {
  const size = 32;
  final pixels = calloc<Uint32>(size * size);

  // Premultiplied BGRA, which is what a 32-bit DIB section wants.
  int argb(int a, int r, int g, int b) =>
      (a << 24) | ((r * a ~/ 255) << 16) | ((g * a ~/ 255) << 8) | (b * a ~/ 255);

  final bodyColour = active ? [235, 70, 80] : [225, 228, 235];
  final body = argb(255, bodyColour[0], bodyColour[1], bodyColour[2]);

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var value = 0; // transparent

      // Capsule: the microphone itself.
      const cx = 16.0, top = 6.0, bottom = 19.0, radius = 5.0;
      final withinX = (x + 0.5 - cx).abs() <= radius;
      final inStraight = withinX && y + 0.5 >= top && y + 0.5 <= bottom;
      final dTop = math.sqrt(math.pow(x + 0.5 - cx, 2) + math.pow(y + 0.5 - top, 2));
      final dBottom =
          math.sqrt(math.pow(x + 0.5 - cx, 2) + math.pow(y + 0.5 - bottom, 2));
      if (inStraight || dTop <= radius || dBottom <= radius) value = body;

      // The cradle: an arc under the capsule.
      final dCentre = math.sqrt(math.pow(x + 0.5 - cx, 2) + math.pow(y + 0.5 - 18, 2));
      if (y + 0.5 > 18 && dCentre >= 8.5 && dCentre <= 10.0) value = body;

      // Stem and base.
      if (withinX && (x + 0.5 - cx).abs() <= 1.2 && y >= 27 && y <= 29) value = body;
      if (y >= 29 && y <= 30 && (x + 0.5 - cx).abs() <= 5) value = body;

      pixels[y * size + x] = value;
    }
  }

  final colour = CreateBitmap(size, size, 1, 32, pixels.cast());
  // A 32-bit colour bitmap carries its own alpha, so the mask is unused —
  // but ICONINFO still requires one.
  final maskBits = calloc<Uint8>(size * size ~/ 8);
  final mask = CreateBitmap(size, size, 1, 1, maskBits.cast());

  final info = calloc<ICONINFO>()
    ..ref.fIcon = true
    ..ref.hbmMask = mask
    ..ref.hbmColor = colour;
  final icon = CreateIconIndirect(info);

  DeleteObject(HGDIOBJ(colour));
  DeleteObject(HGDIOBJ(mask));
  calloc
    ..free(pixels)
    ..free(maskBits)
    ..free(info);
  return icon.value.address;
}

/// The icon for the current state, made once and reused.
int _iconFor(UiStatus status) {
  final active =
      status == UiStatus.listening || status == UiStatus.recognising;
  if (active) {
    if (_activeIcon == 0) _activeIcon = _makeIcon(active: true);
    return _activeIcon;
  }
  if (_idleIcon == 0) _idleIcon = _makeIcon(active: false);
  return _idleIcon;
}

// ─── tray ──────────────────────────────────────────────────────────────────

void _addTrayIcon() {
  final data = calloc<NOTIFYICONDATA>()
    ..ref.cbSize = sizeOf<NOTIFYICONDATA>()
    ..ref.hWnd = HWND(Pointer.fromAddress(_messageWindow))
    ..ref.uID = 1
    ..ref.uFlags = NOTIFY_ICON_DATA_FLAGS(NIF_ICON | NIF_MESSAGE | NIF_TIP)
    ..ref.uCallbackMessage = _trayCallback
    ..ref.hIcon = HICON(Pointer.fromAddress(_iconFor(UiStatus.loading)))
    ..ref.szTip = 'Dictation — starting…';
  _trayData = data;
  Shell_NotifyIcon(NOTIFY_ICON_MESSAGE(NIM_ADD), data);
}

void _removeTrayIcon() {
  if (_trayData case final data?) {
    Shell_NotifyIcon(NOTIFY_ICON_MESSAGE(NIM_DELETE), data);
    calloc.free(data);
    _trayData = null;
  }
}

String get _statusText => switch (_status) {
      UiStatus.loading => 'Loading models…',
      UiStatus.ready => 'Ready — hold $_hotkeyLabel',
      UiStatus.listening => 'Listening',
      UiStatus.recognising => 'Recognising',
      UiStatus.paused => 'Paused',
      UiStatus.failed => 'Error — see the console',
    };

void _applyStatus() {
  final data = _trayData;
  if (data == null) return;
  // Icon as well as tooltip: the colour is what someone actually reads when
  // they glance at the tray to see whether it is listening.
  data.ref
    ..uFlags = NOTIFY_ICON_DATA_FLAGS(NIF_TIP | NIF_ICON)
    ..hIcon = HICON(Pointer.fromAddress(_iconFor(_status)))
    ..szTip = 'Dictation — $_statusText';
  Shell_NotifyIcon(NOTIFY_ICON_MESSAGE(NIM_MODIFY), data);
}

void _showMenu(int hwnd) {
  final menu = CreatePopupMenu().value;
  final labels = <Pointer<Utf16>>[];

  void item(int id, String text, {bool enabled = true}) {
    final ptr = text.toNativeUtf16();
    labels.add(ptr);
    AppendMenu(
      menu,
      MENU_ITEM_FLAGS(MF_STRING | (enabled ? 0 : MF_GRAYED)),
      id,
      PCWSTR(ptr),
    );
  }

  item(0, _statusText, enabled: false);
  AppendMenu(menu, MENU_ITEM_FLAGS(MF_SEPARATOR), 0, null);
  item(UiMenu.pause, _paused ? 'Resume' : 'Pause');
  item(UiMenu.settings, 'Edit settings…');
  item(UiMenu.reload, 'Reload settings');
  AppendMenu(menu, MENU_ITEM_FLAGS(MF_SEPARATOR), 0, null);
  item(UiMenu.quit, 'Quit');

  final point = calloc<POINT>();
  GetCursorPos(point);
  final window = HWND(Pointer.fromAddress(hwnd));

  // Windows will not dismiss a tray menu on an outside click unless its owner
  // is foreground first; the WM_NULL afterwards is the documented companion.
  SetForegroundWindow(window);
  TrackPopupMenu(
    menu,
    TRACK_POPUP_MENU_FLAGS(TPM_RIGHTBUTTON),
    point.ref.x,
    point.ref.y,
    window,
    nullptr,
  );
  PostMessage(window, WM_NULL, WPARAM(0), LPARAM(0));

  DestroyMenu(menu);
  calloc.free(point);
  for (final label in labels) {
    calloc.free(label);
  }
}

// ─── overlay ───────────────────────────────────────────────────────────────

/// Not surfaced by the win32 package, so bound by hand.
final _createRoundRectRgn = DynamicLibrary.open('gdi32.dll').lookupFunction<
    IntPtr Function(Int32, Int32, Int32, Int32, Int32, Int32),
    int Function(int, int, int, int, int, int)>('CreateRoundRectRgn');

int _overlayFont = 0;

/// Segoe UI at a readable size.
///
/// The stock device font is a bitmap face from the 1990s and looks it. One
/// `CreateFont` is the difference between a status pill that looks deliberate
/// and one that looks unfinished.
int _font() {
  if (_overlayFont != 0) return _overlayFont;
  final face = 'Segoe UI'.toNativeUtf16();
  final font = CreateFont(
    -17, 0, 0, 0,
    FW_SEMIBOLD, 0, 0, 0,
    FONT_CHARSET(DEFAULT_CHARSET),
    FONT_OUTPUT_PRECISION(OUT_DEFAULT_PRECIS),
    FONT_CLIP_PRECISION(CLIP_DEFAULT_PRECIS),
    FONT_QUALITY(CLEARTYPE_QUALITY),
    0, // DEFAULT_PITCH | FF_DONTCARE
    PCWSTR(face),
  );
  calloc.free(face);
  _overlayFont = font.address;
  return _overlayFont;
}

void _prepareOverlay() {
  final window = HWND(Pointer.fromAddress(_overlayWindow));
  final index = WINDOW_LONG_PTR_INDEX(GWL_EXSTYLE);
  SetWindowLongPtr(
    window,
    index,
    GetWindowLongPtr(window, index).value | WS_EX_LAYERED,
  );
  SetLayeredWindowAttributes(
    window,
    COLORREF(0),
    235,
    LAYERED_WINDOW_ATTRIBUTES_FLAGS(LWA_ALPHA),
  );

  // Centred near the bottom of the work area — above the taskbar, and clear of
  // where most text fields sit.
  final work = calloc<RECT>();
  SystemParametersInfo(
    SYSTEM_PARAMETERS_INFO_ACTION(SPI_GETWORKAREA),
    0,
    work.cast(),
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
  );
  SetWindowPos(
    window,
    HWND(Pointer.fromAddress(-1)), // HWND_TOPMOST
    work.ref.left + (work.ref.right - work.ref.left - 280) ~/ 2,
    work.ref.bottom - 56 - 120,
    280,
    56,
    SET_WINDOW_POS_FLAGS(SWP_NOACTIVATE),
  );
  calloc.free(work);

  // Rounded corners. A rectangle with sharp corners floating over someone
  // else's window reads as a glitch rather than a control.
  final region = _createRoundRectRgn(0, 0, 281, 57, 18, 18);
  SetWindowRgn(window, HRGN(Pointer.fromAddress(region)), true);
}

void _applyOverlay() {
  final window = HWND(Pointer.fromAddress(_overlayWindow));
  if (_overlayState == UiOverlayState.hidden) {
    ShowWindow(window, SHOW_WINDOW_CMD(SW_HIDE));
    return;
  }
  ShowWindow(window, SHOW_WINDOW_CMD(SW_SHOWNOACTIVATE));
  InvalidateRect(window, nullptr, true);
}

int _overlayProc(int hwnd, int message, int wParam, int lParam) {
  switch (message) {
    case WM_PAINT:
      _paintOverlay(hwnd);
      return 0;
    // The extended style asks Windows not to activate this window; answering
    // the test message says so again, which is what stops a stray click
    // stealing the caret from whatever the words are going into.
    case WM_MOUSEACTIVATE:
      return 3; // MA_NOACTIVATE
    case WM_ERASEBKGND:
      return 1; // painted in full below; erasing first only flickers
  }
  return DefWindowProc(
    HWND(Pointer.fromAddress(hwnd)),
    message,
    WPARAM(wParam),
    LPARAM(lParam),
  );
}

String get _overlayCaption => switch (_overlayState) {
      UiOverlayState.hidden => '',
      UiOverlayState.listening => 'Listening…',
      UiOverlayState.working => 'Recognising…',
      UiOverlayState.failed => 'Something went wrong',
    };

void _paintOverlay(int hwnd) {
  final window = HWND(Pointer.fromAddress(hwnd));
  final ps = calloc<PAINTSTRUCT>();
  final rect = calloc<RECT>();
  try {
    final dc = BeginPaint(window, ps);
    GetClientRect(window, rect);

    final listening = _overlayState == UiOverlayState.listening;
    // Red while the microphone is open, blue while thinking: the colour is the
    // fastest way to tell whether it is still hearing you.
    final accent = switch (_overlayState) {
      UiOverlayState.listening => _rgb(220, 60, 70),
      UiOverlayState.failed => _rgb(230, 160, 60),
      _ => _rgb(70, 120, 220),
    };

    final background = CreateSolidBrush(COLORREF(_rgb(28, 30, 36)));
    FillRect(dc, rect, background);
    DeleteObject(HGDIOBJ(background));

    if (listening) {
      // Inset, so it reads as part of the pill rather than an edge artefact.
      // The square root opens the bottom of the range out: speech spends most
      // of its time quiet, and a linear meter barely moves.
      const inset = 18;
      final track = rect.ref.right - rect.ref.left - inset * 2;
      final filled = (math.sqrt(_level.clamp(0, 1)) * track).round();

      final trough = calloc<RECT>()
        ..ref.left = inset
        ..ref.top = rect.ref.bottom - 11
        ..ref.right = rect.ref.right - inset
        ..ref.bottom = rect.ref.bottom - 8;
      final troughBrush = CreateSolidBrush(COLORREF(_rgb(52, 56, 66)));
      FillRect(dc, trough, troughBrush);
      DeleteObject(HGDIOBJ(troughBrush));

      if (filled > 0) {
        trough.ref.right = inset + filled;
        final brush = CreateSolidBrush(COLORREF(accent));
        FillRect(dc, trough, brush);
        DeleteObject(HGDIOBJ(brush));
      }
      calloc.free(trough);
    }

    final dot = calloc<RECT>()
      ..ref.left = 18
      ..ref.top = 23
      ..ref.right = 28
      ..ref.bottom = 33;
    final dotBrush = CreateSolidBrush(COLORREF(accent));
    FillRect(dc, dot, dotBrush);
    DeleteObject(HGDIOBJ(dotBrush));
    calloc.free(dot);

    SetBkMode(dc, BACKGROUND_MODE(TRANSPARENT));
    SetTextColor(dc, COLORREF(_rgb(238, 240, 245)));
    final previousFont =
        SelectObject(dc, HGDIOBJ(Pointer.fromAddress(_font())));

    final text = _overlayCaption.toNativeUtf16();
    final textRect = calloc<RECT>()
      ..ref.left = 40
      ..ref.top = 0
      ..ref.right = rect.ref.right - 12
      ..ref.bottom = rect.ref.bottom - 4;
    DrawText(
      dc,
      PCWSTR(text),
      -1,
      textRect,
      DRAW_TEXT_FORMAT(DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS),
    );
    calloc.free(textRect);
    calloc.free(text);
    SelectObject(dc, previousFont);

    EndPaint(window, ps);
  } finally {
    calloc.free(ps);
    calloc.free(rect);
  }
}

/// COLORREF is 0x00BBGGRR — the byte order catches everyone once.
int _rgb(int r, int g, int b) => r | (g << 8) | (b << 16);
