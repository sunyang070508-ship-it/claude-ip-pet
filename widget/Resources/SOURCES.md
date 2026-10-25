# 界面与地图资源

- `HUDBackground.png`：项目使用的空白 HUD 界面素材，为桌宠边框及保留的 HUD 渲染器提供装饰图层，不包含真实检测结果。
- `HUDWorld.json`：静态地图数据，包含装饰性陆地点及国家 / 地区标签锚点；运行时不通过它请求定位接口。
- `src/web/hud-world.js`：供桌宠页面使用的对应地图数据。

地图数据来源：

- [Natural Earth 1:110m countries](https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_admin_0_countries.geojson)
- [Natural Earth 1:50m countries](https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_50m_admin_0_countries.geojson)
- [Natural Earth 使用条款](https://www.naturalearthdata.com/about/terms-of-use/)

所有锚点均为国家级示意点，不代表精确用户、IP 或城市坐标。地图投影、陆地点、轨道及定位连线属于呈现层；检测数据来自独立的数据层。

刷新呈现由 `RefreshPresentation.swift` 管理，与原站请求及评分规则分离。组件使用不透明浅色渐变，桌宠使用深色 HUD；生成图片、实时截图和本机验证记录不属于运行资源。
