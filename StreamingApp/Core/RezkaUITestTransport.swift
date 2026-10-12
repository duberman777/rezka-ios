#if DEBUG
import Foundation

struct RezkaUITestTransport: RezkaTransport {
    func send(_ request: URLRequest) async throws -> RezkaHTTPResponse {
        guard let url = request.url else { throw RezkaError.invalidURL }
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-polish"), !url.path.contains("get_cdn_series") {
            return RezkaHTTPResponse(data: Data(polishHTML(url: url).utf8), url: url, statusCode: 200)
        }
        let series = ProcessInfo.processInfo.arguments.contains("--rezka-ui-series")
        let seriesPage = url.path.contains("/series/") || series
        let text: String
        if url.path.contains("get_cdn_series") {
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            var response: [String: Any] = ["success": true, "url": "[720p]https://video.test/stream?id=42",
                "subtitle": "", "subtitle_lns": [:], "subtitle_def": "0"]
            if form.contains("get_episodes") {
                response["seasons"] = "<li class='b-simple_season__item' data-tab_id='1'>Season 1</li><li class='b-simple_season__item' data-tab_id='2'>Season 2</li>"
                response["episodes"] = "<div id='simple-episodes-list-1'><li class='b-simple_episode__item' data-episode_id='1'>First episode</li></div><div id='simple-episodes-list-2'><li class='b-simple_episode__item' data-episode_id='1'>Second episode</li></div>"
            }
            return RezkaHTTPResponse(data: try JSONSerialization.data(withJSONObject: response), url: url, statusCode: 200)
        } else if url.path.contains("42-screen-test") {
            text = """
            <div class="b-content__main"><div class="b-post__title"><h1 itemprop="name">Screen test title</h1></div>
            <div class="b-post__description_text">A title for testing the native detail and playback screens.</div>
            <div class="b-translator__item active b-prem_translator" data-translator_id="9">Premium dub</div>
            <div class="b-translator__item" data-translator_id="7">Original</div></div>
            <script>sof.tv.initCDN\(series ? "Series" : "Movies")Events(42, 9, 0);</script>
            """
        } else if url.path == "/collections/" || url.path == "/collections" {
            text = """
            <div class='b-content__collections_item' data-url='/collections/screen-test/'>
            <div class='title'>Screen test collection</div><div class='num'>1 title</div></div>
            """
        } else {
            text = """
            <div class="b-content__inline_item" data-id="42" data-url="/\(seriesPage ? "series" : "films")/42-screen-test.html">
            <div class="b-content__inline_item-link"><a href="/\(series ? "series" : "films")/42-screen-test.html">Screen test title</a><div>2026, Italy, Drama</div></div></div>
            """
        }
        return RezkaHTTPResponse(data: Data(text.utf8), url: url, statusCode: 200)
    }

    private func polishHTML(url: URL) -> String {
        let original = "https://static.hdrezka.ac/i/2026/9/28/tb27ff9f15855vt64s44f.jpg"
        let thumbnail = "https://static.hdrezka.ac/i/2026/9/28/ae7c7241906d0gz33l80y.jpg"
        if url.path.contains("42-screen-test") || url.path.contains("43-screen-test") {
            return """
            <div class='b-content__main'><div class='b-post__title'><h1 itemprop='name'>Глубина</h1></div>
            <div class='b-post__origtitle'>The Deep</div>
            <div class='b-sidecover'><a href='\(original)' data-imagelightbox='cover'><img src='\(thumbnail)'></a></div>
            <div class='b-post__description_text'>В отдалённом рыбацком городке появляется загадочное морское существо, превращая жизнь местных жителей в хаос. Когда начинают исчезать люди, две семьи пытаются раскрыть тайну. Непредсказуемые события вынуждают героев заново взглянуть на свой город, отношения и секреты прошлого.</div>
            <table class='b-post__info'>
            <tr><td class='l'><h2>Дата выхода</h2></td><td>8 октября 2026 года</td></tr>
            <tr><td class='l'><h2>Страна</h2></td><td>Канада</td></tr>
            <tr><td class='l'><h2>Возраст</h2></td><td>16+ Для зрителей старше шестнадцати лет</td></tr>
            <tr><td class='l'><h2>Время</h2></td><td>55 мин.</td></tr>
            <tr><td class='l'><h2>Жанр</h2></td><td><span itemprop='genre'>Драмы</span>, <span itemprop='genre'>Ужасы</span></td></tr>
            <tr><td class='l'><h2>Рейтинги</h2></td><td>Duplicate website ratings</td></tr>
            <tr><td><a href='/collections/coastal-mysteries/'>Истории загадочных прибрежных городов</a></td></tr>
            <tr><td><a href='/best/drama/'>Лучшие драматические сериалы 2026 года</a></td></tr>
            </table>
            <div class='b-post__info_rates imdb'><b class='bold'>6.5</b><a href='https://imdb.com/'>IMDb</a></div>
            <span itemprop='director' data-photo='https://static.hdrezka.ac/i/2018/6/7/a94ecffac8753zu16c77n.jpg'><a href='/person/197787-jamie-childs/'><span itemprop='name'>Джейми Чайлдс</span></a></span>
            <span itemprop='actor' data-photo='https://static.hdrezka.ac/i/2016/3/10/ge7345e121cb8ni26y97r.jpg'><a href='/person/11733-dzhosh-hartnett/'><span itemprop='name'>Джош Хартнетт</span></a></span>
            <span itemprop='actor' data-photo='https://static.hdrezka.ac/i/2016/3/10/df325efa828a9bv54z49h.jpg'><a href='/person/9689-makkenzi-devis/'><span itemprop='name'>Маккензи Дэвис</span></a></span>
            <div class='b-translator__item' data-translator_id='7'>Дубляж (официальный)</div></div>
            <script>sof.tv.initCDNSeriesEvents(42, 7, 0);</script>
            <div class='b-post__schedule_block'><div class='b-post__schedule_block_title'><span class='title'>Глубина - даты выхода серий 1 сезона</span></div>
            <table class='b-post__schedule_table'><tbody>
            <tr><td class='td-1'>1 сезон 6 серия</td><td class='td-2'><b>Бездна сиротства</b></td><td class='td-4'>9 октября 2026</td></tr>
            <tr><td class='td-1'>1 сезон 5 серия</td><td class='td-2'><b>Литтл-Пот-Рок</b></td><td class='td-4'>9 октября 2026</td></tr>
            <tr><td class='td-1'>1 сезон 4 серия</td><td class='td-2'><b>Океан поглотит нас всех</b></td><td class='td-4'>9 октября 2026</td></tr>
            <tr><td class='td-1'>1 сезон 3 серия</td><td class='td-2'><b>Сэр Джон Франклин</b></td><td class='td-4'>9 октября 2026</td></tr>
            <tr><td class='td-1'>1 сезон 2 серия</td><td class='td-2'><b>Корона и якорь</b></td><td class='td-4'>9 октября 2026</td></tr>
            <tr><td class='td-1'>1 сезон 1 серия</td><td class='td-2'><b>Год возвращения домой</b></td><td class='td-4'>9 октября 2026</td></tr>
            </tbody></table></div>
            <div class='b-post__franchise_link_title'>Related stories</div>
            <div class='b-post__partcontent_item'><span class='td title'><a href='/series/43-screen-test.html'>Ещё одна история с длинным названием для проверки переноса текста</a></span><span class='td year'>2025</span></div>
            """
        }
        if url.path.contains("collections") {
            return "<div class='b-content__collections_item' data-url='/collections/coastal-mysteries/'><div class='title'>Загадочные истории</div><div class='num'>12 titles</div><img src='\(original)'></div>"
        }
        let categoryLinks = [
            ("films/western", "Вестерны"), ("films/family", "Семейные"), ("films/fantasy", "Фэнтези"),
            ("films/biographical", "Биографические"), ("films/arthouse", "Арт-хаус"), ("films/action", "Боевики"),
            ("films/military", "Военные"), ("films/detective", "Детективы"), ("series/drama", "Драмы"),
            ("cartoons/fairytale", "Сказки"), ("animation/mecha", "Меха")
        ].map { "<a href='/\($0.0)/'>\($0.1)</a>" }.joined()
        return categoryLinks + (42...47).map { id in
            """
            <div class='b-content__inline_item' data-id='\(id)' data-url='/series/\(id)-screen-test.html'><img src='\(thumbnail)'>
            <div class='b-content__inline_item-link'><a href='/series/\(id)-screen-test.html'>\(id == 42 ? "Глубина" : "Истории побережья")</a><div>2026, Canada, Драмы, Ужасы</div></div></div>
            """
        }.joined()
    }
}
#endif
