import '../../src/dtmf.dart';

void main(){
  final dep = DTMFDepacketizer({
  'output': (chunk) {
    print("DTMF: ${chunk['symbol']}, end=${chunk['end']}");
  }
});
}