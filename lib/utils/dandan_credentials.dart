// DanDanPlay API credentials for the client signature flow.
// [my修改] 改回上游机制: 编译期 --dart-define 注入, 仓库内不留真实值。
// 真实凭证放在仓库外的 ../secrets.env (永不入版本控制), 构建用外层的 build.bat 自动读取。
// 未注入时为空串, 弹幕签名失效但不崩溃 (与上游源码直接构建的行为一致)。
const Map<String, String> dandanCredentials = {
  'id': String.fromEnvironment('DANDANAPI_APPID'),
  'value': String.fromEnvironment('DANDANAPI_KEY'),
};
