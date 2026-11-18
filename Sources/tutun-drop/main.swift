import Darwin

// tutun-drop — запускается службой tutund (root) вместо ядер.
// Переводит процесс в группу _tutun (по ней PF отличает трафик ядер от остального, см. FirewallRules) и,
// если не указан --root, сбрасывает права до пользователя nobody. Затем заменяет себя указанной программой (execv):
// номер процесса, сигналы и код выхода дальше принадлежат самому ядру.
//
//   tutun-drop <абсолютный путь программы> [аргументы…]          — nobody:_tutun; xray и вспомогательный sing-box,
//                                                                   которые разбирают конфиги серверов от провайдера
//   tutun-drop --root <абсолютный путь программы> [аргументы…]   — root:_tutun; sing-box туннеля (без root не создать utun,
//                                                                   его конфиг Tutun строит сам)
// Конфиг ядро без прав получает через стандартный ввод, поэтому файлы с ключами остаются доступны только root.

func die(_ message: String) -> Never {
    fputs("tutun-drop: \(message)\n", stderr)
    exit(126)
}

var args = Array(CommandLine.arguments.dropFirst())
let keepRoot = args.first == "--root"
if keepRoot { args.removeFirst() }
guard let program = args.first, program.hasPrefix("/") else { die("нужен абсолютный путь программы") }
guard getuid() == 0 else { die("запускается только службой Tutun (root)") }
guard let gr = getgrnam("_tutun") else { die("в системе нет группы _tutun — переустановите службу Tutun") }
let gid = gr.pointee.gr_gid
guard gid != 0 else { die("группа _tutun не должна быть группой root") }

// Порядок важен: сначала группы, потом gid, последним uid — после него менять группы уже нельзя.
var groups = [gid]
guard setgroups(1, &groups) == 0 else { die("setgroups: \(String(cString: strerror(errno)))") }
guard setgid(gid) == 0 else { die("setgid: \(String(cString: strerror(errno)))") }
guard getgid() == gid, getegid() == gid else { die("группа не установлена") }

if !keepRoot {
    guard let pw = getpwnam("nobody") else { die("в системе нет пользователя nobody") }
    let uid = pw.pointee.pw_uid
    guard uid != 0 else { die("пользователь nobody не должен быть root") }
    guard setuid(uid) == 0 else { die("setuid: \(String(cString: strerror(errno)))") }
    // Права сброшены насовсем: реальный, действующий и сохранённый id — nobody, вернуть root нельзя.
    guard getuid() == uid, geteuid() == uid, setuid(0) != 0, seteuid(0) != 0 else { die("права не сброшены") }
}

var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
cargs.append(nil)
execv(program, cargs)
die("не запустить \(program): \(String(cString: strerror(errno)))")
