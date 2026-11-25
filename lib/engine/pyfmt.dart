/// Arrondi et formatage identiques à Python (`round(x, n)` et `f"{x:.nf}"`).
///
/// Python arrondit la valeur binaire EXACTE du double, avec « au pair le plus
/// proche » sur les égalités exactes (ex. round(0.125, 2) == 0.12), alors que
/// `toStringAsFixed` de Dart arrondit les égalités vers le haut. La parité des
/// KPI et des messages avec le moteur Python exige le même comportement.
library;

import 'dart:typed_data';

final BigInt _ten = BigInt.from(10);

/// Décompose [x] (fini, non nul) en mantisse entière et exposant : |x| = m · 2^e.
(BigInt, int) _decompose(double x) {
  final bd = ByteData(8)..setFloat64(0, x.abs());
  final hi = bd.getUint32(0);
  final lo = bd.getUint32(4);
  final exp = (hi >> 20) & 0x7FF;
  var mant = (BigInt.from(hi & 0xFFFFF) << 32) | BigInt.from(lo);
  int e;
  if (exp == 0) {
    e = -1074; // sous-normal
  } else {
    mant = mant | (BigInt.one << 52);
    e = exp - 1075;
  }
  return (mant, e);
}

/// Entier N = arrondi au pair de |x| · 10^n (valeur exacte du double).
BigInt _scaledHalfEven(double x, int n) {
  final (m, e) = _decompose(x);
  final pow10 = _ten.pow(n);
  if (e >= 0) return (m << e) * pow10;
  final num = m * pow10;
  final den = BigInt.one << (-e);
  var q = num ~/ den;
  final r2 = (num - q * den) * BigInt.two;
  final c = r2.compareTo(den);
  if (c > 0 || (c == 0 && q.isOdd)) q += BigInt.one;
  return q;
}

/// Équivalent de `f"{x:.{n}f}"` (point décimal, sans séparateur de milliers).
String pyFixed(double x, int n) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x > 0 ? 'inf' : '-inf';
  final neg = x.isNegative; // -0.0 compris, comme Python
  final s = (x == 0 ? BigInt.zero : _scaledHalfEven(x, n)).toString();
  String body;
  if (n == 0) {
    body = s;
  } else {
    final padded = s.padLeft(n + 1, '0');
    body = '${padded.substring(0, padded.length - n)}.${padded.substring(padded.length - n)}';
  }
  return neg ? '-$body' : body;
}

/// Équivalent de `round(x, n)` pour un float Python.
double pyRound(double x, int n) {
  if (x.isNaN || x.isInfinite || x == 0) return x;
  // Chemin rapide : loin d'une égalité, l'arrondi classique est exact.
  final p = _pow10(n);
  final s = x * p;
  if (s.abs() < 1e15) {
    final f = s - s.floorToDouble();
    if ((f - 0.5).abs() > 1e-6) {
      final r = (f < 0.5 ? s.floorToDouble() : s.floorToDouble() + 1) / p;
      // la division peut introduire 1 ulp d'écart : on repasse par le texte
      return double.parse(pyFixed(r, n));
    }
  }
  return double.parse(pyFixed(x, n));
}

double _pow10(int n) {
  var p = 1.0;
  for (var i = 0; i < n; i++) {
    p *= 10;
  }
  return p;
}

/// Python `math.ceil` sur un float (renvoie un entier).
int pyCeil(double x) => x.ceil();

/// Python `str(int)` / `str(float)` simplifié pour les numéros de station.
String pyStr(num v) => v is int ? '$v' : v.toString();
