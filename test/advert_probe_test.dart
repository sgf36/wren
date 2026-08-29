/// Runs the advert beats on the fake clock, headless, as part of the ordinary
/// suite.
///
/// The beats themselves need a simulator and about eight minutes, and produce a
/// video whose only real verdict is a person watching it. But almost nothing
/// that goes wrong with them is about video. It is a scene that was renamed, a
/// button whose string moved, a list that stopped being scrollable — sequence
/// faults, every one of which is answerable here in under a second and which
/// otherwise show up as a black clip after a simulator boot.
///
/// So this imports the same file `store/record.py` drives, flips it onto the
/// fake clock, and runs it. No frames are drawn and no timing is checked; what
/// is checked is that the sequence can be performed at all.
///
/// If this fails, `advert-footage.yml` will fail too, and for the same reason.
library;

import '../integration_test/advert_test.dart' as advert;

void main() {
  advert.probeMode = true;
  advert.main();
}
