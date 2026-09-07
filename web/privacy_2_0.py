"""Add the shared-post disclosure to the fifteen translated privacy pages.

    python web/privacy_2_0.py            # show what would change
    python web/privacy_2_0.py --write    # rewrite the files

The English page says, in full, what happens when somebody shares a reel: what
is sent, what comes back, what is kept and which other companies touch it. The
translated pages still say that entering a complimentary code is the only time
Wren contacts a server of its own, which stops being true the moment this ships.

Edited by LINE NUMBER, not by matching translated text. All fifteen translated
privacy pages are 673 lines and share one structure — they came from one English
original and none has drifted — so the short-version paragraph is line 159 in
every one of them. Matching on text would mean holding fifteen translations of
the old wording just to find it. Every anchor is checked before it is touched,
and the file is refused if the shape is not what this expects.

The translated version is shorter than the English one, following the pattern
this project already uses for the complimentary-code disclosure: English
precise, the others complete but compact. Everything material is here — what is
sent, what comes back, what is kept, and that two named third parties are
involved.
"""
import argparse
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

LINES = 673  # and no trailing newline
SHORT_VERSION = 159        # the "the app has no accounts" paragraph
AFTER_SCREENSHOTS = 267    # the </section> that closes "your screenshots"

# The heading and three paragraphs, per language. `head` is the <h2>.
TEXT = {
 'fr': {
  'short': "<p><strong>L'application</strong> ne comporte ni compte ni analyse. Vos captures d'écran et tout fichier que vous importez sont lus sur votre téléphone et ne sont jamais téléversés. Deux choses seulement atteignent un serveur de Wren, et uniquement à votre demande : un code d'accès gratuit, si l'on vous en a remis un et que vous le saisissez ; et le lien d'un reel ou d'une publication, si vous en partagez un pour que Wren le lise. Cette publication est récupérée, lue, puis jetée — rien n'en est conservé, ni la vidéo, ni les mots, ni les noms de lieux.</p>",
  'head': "Un reel ou une publication que vous partagez",
  'p1': "C'est la seule partie de Wren qui envoie à un serveur de Wren quelque chose que vous avez choisi, et cela n'arrive que lorsque vous partagez ou collez le lien d'un reel ou d'une publication. Wren ne peut pas la lire sur le téléphone : une feuille de partage transmet une adresse web et jamais la vidéo.",
  'p2': "<strong>Ce qui est envoyé, c'est le lien et la preuve que vous avez acheté la fonctionnalité.</strong> Rien d'autre — ni nom, ni adresse e-mail, ni position, ni capture d'écran. Le serveur récupère la publication, fait lire les noms de lieux par un modèle de langage, renvoie les <em>noms</em> à votre téléphone et jette le reste. <strong>Rien de la publication n'est stocké : ni l'adresse, ni la vidéo, ni la légende, ni les noms trouvés.</strong> Une seule ligne est écrite, et elle indique uniquement qu'un achat a consommé une unité de son quota mensuel.",
  'p3': "Deux autres sociétés interviennent à ce moment-là et aucune n'apprend qui vous êtes : un service nommé ScrapeCreators récupère la publication auprès de la plateforme qui l'héberge, et Vertex AI de Google exécute le modèle qui la lit. Google indique que les données envoyées à Vertex AI ne servent pas à entraîner ses modèles. Wren n'est affilié ni à Instagram, ni à TikTok, ni à YouTube, et ne demande jamais qu'une publication que vous avez choisi de partager.",
 },
 'de': {
  'short': "<p><strong>Die App</strong> hat keine Konten und keine Analyse-Software. Ihre Screenshots und jede Datei, die Sie importieren, werden auf Ihrem Telefon gelesen und niemals hochgeladen. Nur zwei Dinge erreichen einen Server von Wren, und auch nur auf Ihre Bitte hin: ein kostenloser Zugangscode, wenn Ihnen einer gegeben wurde und Sie ihn eingeben; und der Link zu einem Reel oder Beitrag, wenn Sie einen zum Lesen teilen. Dieser Beitrag wird geholt, gelesen und verworfen — nichts davon wird behalten, weder das Video noch die Worte noch die Ortsnamen.</p>",
  'head': "Ein Reel oder Beitrag, den Sie teilen",
  'p1': "Dies ist der einzige Teil von Wren, der etwas von Ihnen Gewähltes an einen Server von Wren sendet, und er geschieht nur, wenn Sie den Link zu einem Reel oder Beitrag teilen oder einfügen. Wren kann ihn auf dem Telefon nicht lesen: Ein Teilen-Menü übergibt eine Webadresse und niemals das Video.",
  'p2': "<strong>Gesendet werden der Link und ein Nachweis, dass Sie die Funktion gekauft haben.</strong> Sonst nichts — kein Name, keine E-Mail-Adresse, kein Standort, kein Screenshot. Der Server holt den Beitrag, lässt ein Sprachmodell die Ortsnamen daraus lesen, schickt die <em>Namen</em> an Ihr Telefon zurück und verwirft den Rest. <strong>Vom Beitrag wird nichts gespeichert: weder die Adresse noch das Video, weder die Bildunterschrift noch die gefundenen Namen.</strong> Geschrieben wird eine einzige Zeile, und sie besagt nur, dass ein Kauf eine Einheit seines Monatskontingents verbraucht hat.",
  'p3': "Zwei weitere Unternehmen sind in diesem Moment beteiligt, und keines erfährt, wer Sie sind: Ein Dienst namens ScrapeCreators holt den Beitrag von der Plattform, die ihn hostet, und Googles Vertex AI führt das Modell aus, das ihn liest. Google gibt an, dass an Vertex AI gesendete Daten nicht zum Training seiner Modelle verwendet werden. Wren steht in keiner Verbindung zu Instagram, TikTok oder YouTube und fragt immer nur nach einem Beitrag, den Sie zu teilen gewählt haben.",
 },
 'es': {
  'short': "<p><strong>La aplicación</strong> no tiene cuentas ni analíticas. Tus capturas de pantalla y cualquier archivo que importes se leen en tu teléfono y nunca se suben. Solo dos cosas llegan a un servidor de Wren, y solo cuando tú lo pides: un código de acceso de cortesía, si te dieron uno y lo introduces; y el enlace de un reel o una publicación, si compartes uno para que Wren lo lea. Esa publicación se obtiene, se lee y se descarta: no se guarda nada de ella, ni el vídeo, ni las palabras, ni los nombres de los lugares.</p>",
  'head': "Un reel o una publicación que compartes",
  'p1': "Esta es la única parte de Wren que envía a un servidor de Wren algo que tú has elegido, y solo ocurre cuando compartes o pegas el enlace de un reel o una publicación. Wren no puede leerla en el teléfono: una hoja de compartir entrega una dirección web y nunca el vídeo.",
  'p2': "<strong>Lo que se envía es el enlace y la prueba de que compraste la función.</strong> Nada más: ni nombre, ni correo, ni ubicación, ni capturas. El servidor obtiene la publicación, hace que un modelo de lenguaje lea los nombres de lugares, devuelve los <em>nombres</em> a tu teléfono y descarta el resto. <strong>No se almacena nada de la publicación: ni la dirección, ni el vídeo, ni el texto, ni los nombres encontrados.</strong> Se escribe una sola fila, y solo dice que una compra gastó una unidad de su cuota mensual.",
  'p3': "En ese momento intervienen otras dos empresas y ninguna sabe quién eres: un servicio llamado ScrapeCreators obtiene la publicación de la plataforma que la aloja, y Vertex AI de Google ejecuta el modelo que la lee. Google indica que los datos enviados a Vertex AI no se usan para entrenar sus modelos. Wren no está afiliado a Instagram, TikTok ni YouTube, y solo pide una publicación que tú has elegido compartir.",
 },
 'pt': {
  'short': "<p><strong>A aplicação</strong> não tem contas nem análises. As tuas capturas de ecrã e qualquer ficheiro que importes são lidos no teu telemóvel e nunca são enviados. Só duas coisas chegam a um servidor do Wren, e apenas quando pedes: um código de acesso de cortesia, se te deram um e o introduzires; e o link de um reel ou de uma publicação, se partilhares um para o Wren ler. Essa publicação é obtida, lida e descartada — nada dela é guardado, nem o vídeo, nem as palavras, nem os nomes dos lugares.</p>",
  'head': "Um reel ou uma publicação que partilhas",
  'p1': "Esta é a única parte do Wren que envia para um servidor do Wren algo que tu escolheste, e só acontece quando partilhas ou colas o link de um reel ou de uma publicação. O Wren não a consegue ler no telemóvel: uma folha de partilha entrega um endereço web e nunca o vídeo.",
  'p2': "<strong>O que é enviado é o link e a prova de que compraste a funcionalidade.</strong> Mais nada — nem nome, nem email, nem localização, nem capturas. O servidor obtém a publicação, faz um modelo de linguagem ler os nomes dos lugares, devolve os <em>nomes</em> ao teu telemóvel e descarta o resto. <strong>Nada da publicação é armazenado: nem o endereço, nem o vídeo, nem a legenda, nem os nomes encontrados.</strong> É escrita uma única linha, e diz apenas que uma compra gastou uma unidade da sua quota mensal.",
  'p3': "Nesse momento intervêm outras duas empresas e nenhuma fica a saber quem tu és: um serviço chamado ScrapeCreators obtém a publicação da plataforma que a aloja, e o Vertex AI da Google executa o modelo que a lê. A Google indica que os dados enviados ao Vertex AI não são usados para treinar os seus modelos. O Wren não é afiliado do Instagram, do TikTok nem do YouTube, e só pede uma publicação que tu escolheste partilhar.",
 },
 'sv': {
  'short': "<p><strong>Appen</strong> har inga konton och ingen analys. Dina skärmbilder och alla filer du importerar läses på din telefon och laddas aldrig upp. Bara två saker når en server som Wren driver, och bara när du ber om det: en gratis åtkomstkod, om du fått en och matar in den; och länken till en reel eller ett inlägg, om du delar ett för Wren att läsa. Det inlägget hämtas, läses och kastas — ingenting av det behålls, varken videon, orden eller platsnamnen.</p>",
  'head': "En reel eller ett inlägg som du delar",
  'p1': "Detta är den enda delen av Wren som skickar något du valt till en server Wren driver, och det sker bara när du delar eller klistrar in länken till en reel eller ett inlägg. Wren kan inte läsa det på telefonen: ett delningsblad lämnar över en webbadress och aldrig videon.",
  'p2': "<strong>Det som skickas är länken och ett bevis på att du köpt funktionen.</strong> Inget annat — inget namn, ingen e-postadress, ingen plats, inga skärmbilder. Servern hämtar inlägget, låter en språkmodell läsa ut platsnamnen, skickar tillbaka <em>namnen</em> till din telefon och kastar resten. <strong>Ingenting om inlägget lagras: varken adressen, videon, bildtexten eller namnen som hittades.</strong> En enda rad skrivs, och den säger bara att ett köp förbrukat en enhet av sin månadskvot.",
  'p3': "Två andra företag är inblandade i det ögonblicket och inget av dem får veta vem du är: en tjänst som heter ScrapeCreators hämtar inlägget från plattformen som är värd för det, och Googles Vertex AI kör modellen som läser det. Google uppger att data som skickas till Vertex AI inte används för att träna deras modeller. Wren är inte knutet till Instagram, TikTok eller YouTube och ber alltid bara om ett inlägg som du valt att dela.",
 },
 'ru': {
  'short': "<p><strong>Приложение</strong> не имеет учётных записей и аналитики. Ваши скриншоты и любые импортированные файлы читаются на телефоне и никогда не выгружаются. К серверу Wren попадают лишь две вещи, и только по вашей просьбе: код бесплатного доступа, если вам его выдали и вы его ввели; и ссылка на рилс или публикацию, если вы делитесь ею, чтобы Wren её прочитал. Эта публикация загружается, прочитывается и выбрасывается — от неё не остаётся ничего: ни видео, ни слов, ни названий мест.</p>",
  'head': "Рилс или публикация, которой вы делитесь",
  'p1': "Это единственная часть Wren, которая отправляет на сервер Wren то, что вы выбрали, и происходит это только когда вы делитесь ссылкой на рилс или публикацию либо вставляете её. Wren не может прочитать её на телефоне: меню «Поделиться» передаёт веб-адрес и никогда — видео.",
  'p2': "<strong>Отправляются ссылка и подтверждение того, что вы купили эту функцию.</strong> Больше ничего — ни имени, ни адреса почты, ни местоположения, ни скриншотов. Сервер загружает публикацию, языковая модель вычитывает из неё названия мест, <em>названия</em> возвращаются на ваш телефон, остальное выбрасывается. <strong>О публикации не сохраняется ничего: ни адрес, ни видео, ни подпись, ни найденные названия.</strong> Записывается одна строка, и говорит она лишь о том, что одна покупка израсходовала единицу своего месячного лимита.",
  'p3': "В этот момент задействованы ещё две компании, и ни одна не узнаёт, кто вы: сервис ScrapeCreators загружает публикацию с платформы, где она размещена, а Vertex AI от Google выполняет модель, которая её читает. Google заявляет, что данные, отправленные в Vertex AI, не используются для обучения её моделей. Wren не связан с Instagram, TikTok или YouTube и всегда запрашивает только ту публикацию, которой вы решили поделиться.",
 },
 'id': {
  'short': "<p><strong>Aplikasi ini</strong> tidak punya akun dan tidak memakai analitik. Tangkapan layar dan berkas apa pun yang kamu impor dibaca di ponselmu dan tidak pernah diunggah. Hanya dua hal yang sampai ke server milik Wren, dan hanya saat kamu memintanya: kode akses gratis, jika kamu diberi satu dan memasukkannya; dan tautan reel atau unggahan, jika kamu membagikannya untuk dibaca Wren. Unggahan itu diambil, dibaca, lalu dibuang — tidak ada yang disimpan, tidak videonya, tidak kata-katanya, tidak nama tempatnya.</p>",
  'head': "Reel atau unggahan yang kamu bagikan",
  'p1': "Ini satu-satunya bagian Wren yang mengirim sesuatu pilihanmu ke server milik Wren, dan itu hanya terjadi saat kamu membagikan atau menempelkan tautan reel atau unggahan. Wren tidak bisa membacanya di ponsel: lembar berbagi menyerahkan alamat web dan tidak pernah videonya.",
  'p2': "<strong>Yang dikirim adalah tautannya dan bukti bahwa kamu membeli fiturnya.</strong> Tidak ada yang lain — tidak nama, tidak alamat surel, tidak lokasi, tidak tangkapan layar. Server mengambil unggahan itu, membuat model bahasa membaca nama-nama tempat darinya, mengembalikan <em>namanya</em> ke ponselmu, dan membuang sisanya. <strong>Tidak ada yang disimpan tentang unggahan itu: tidak alamatnya, tidak videonya, tidak keterangannya, tidak nama-nama yang ditemukan.</strong> Satu baris ditulis, dan itu hanya menyatakan bahwa satu pembelian memakai satu unit jatah bulanannya.",
  'p3': "Dua perusahaan lain terlibat pada saat itu dan tidak satu pun tahu siapa kamu: layanan bernama ScrapeCreators mengambil unggahan dari platform yang menampungnya, dan Vertex AI milik Google menjalankan model yang membacanya. Google menyatakan bahwa data yang dikirim ke Vertex AI tidak dipakai untuk melatih modelnya. Wren tidak berafiliasi dengan Instagram, TikTok, atau YouTube, dan hanya meminta unggahan yang kamu pilih untuk dibagikan.",
 },
 'ja': {
  'short': "<p><strong>アプリ</strong>にはアカウントも解析もありません。スクリーンショットも、読み込ませたファイルも、端末の中で読まれ、アップロードされることはありません。Wren のサーバーに届くのは二つだけで、しかもお求めになったときだけです。無償アクセスコードをお持ちで入力なさった場合のそのコードと、リールや投稿を読ませるために共有なさった場合のそのリンクです。その投稿は取得され、読み取られ、破棄されます——動画も、文章も、場所の名前も、何ひとつ残りません。</p>",
  'head': "共有されたリールや投稿について",
  'p1': "ここは、お選びになったものを Wren のサーバーへ送る唯一の部分であり、リールや投稿のリンクを共有または貼り付けたときにだけ起こります。端末の中では読めません。共有シートが渡すのはウェブアドレスであって、動画ではないからです。",
  'p2': "<strong>送られるのは、そのリンクと、機能を購入済みであることの証明だけです。</strong>ほかには何も送りません——氏名も、メールアドレスも、位置情報も、スクリーンショットもです。サーバーは投稿を取得し、言語モデルに場所の名前を読み取らせ、<em>名前</em>を端末へ返し、残りを破棄します。<strong>投稿については何も保存しません。アドレスも、動画も、キャプションも、見つかった名前もです。</strong>書き込まれる行は一つだけで、ある購入が月間割り当てを一件分使ったという事実しか記しません。",
  'p3': "その瞬間には他社が二社関わりますが、いずれもお客様が誰であるかを知りません。ScrapeCreators というサービスが投稿を掲載元のプラットフォームから取得し、Google の Vertex AI がそれを読み取るモデルを実行します。Google は、Vertex AI に送られたデータを自社モデルの学習には使用しないと表明しています。Wren は Instagram、TikTok、YouTube のいずれとも提携しておらず、お客様が共有を選ばれた投稿のみを求めます。",
 },
 'zh': {
  'short': "<p><strong>该应用</strong>没有账户，也没有分析工具。你的截图和你导入的任何文件都在手机上读取，从不上传。只有两样东西会到达 Wren 自己的服务器，而且只在你要求时：一个免费访问码，如果你拿到了并输入它；以及一条 Reels 或帖子的链接，如果你分享出来让 Wren 读取。那条帖子会被取回、读取，然后丢弃——它的任何内容都不会被保留，视频不会，文字不会，地点名字也不会。</p>",
  'head': "你分享的 Reels 或帖子",
  'p1': "这是 Wren 唯一会把你选择的东西发往 Wren 自己服务器的部分，而且只在你分享或粘贴 Reels 或帖子的链接时才发生。Wren 无法在手机上读取它：分享面板交出的是一个网址，从来不是视频。",
  'p2': "<strong>发送的是这条链接，以及你已购买该功能的凭据。</strong>没有别的——没有姓名，没有电子邮箱，没有位置，没有截图。服务器取回该帖子，让语言模型从中读出地点名字，把这些<em>名字</em>送回你的手机，其余一概丢弃。<strong>关于这条帖子，什么都不会存储：网址不会，视频不会，文案不会，找到的名字也不会。</strong>只写下一行记录，它仅仅说明某一笔购买用掉了每月额度中的一次。",
  'p3': "这一刻还有另外两家公司参与，它们都不知道你是谁：一家名为 ScrapeCreators 的服务负责从托管该帖子的平台取回它，Google 的 Vertex AI 运行读取它的模型。Google 声明发送至 Vertex AI 的数据不会用于训练其模型。Wren 与 Instagram、TikTok、YouTube 均无关联，且只会索取你选择分享的那条帖子。",
 },
 'ar': {
  'short': "<p><strong>التطبيق</strong> لا يحتوي على حسابات ولا تحليلات. تُقرأ لقطات شاشتك وأي ملف تستورده على هاتفك ولا تُرفع أبدًا. شيئان فقط يصلان إلى خادم يديره Wren، وذلك عند طلبك فقط: رمز وصول مجاني، إن كان قد أُعطي لك وأدخلته؛ ورابط ريل أو منشور، إن شاركته ليقرأه Wren. يُجلب ذلك المنشور ويُقرأ ثم يُتلَف — لا يُحتفظ بشيء منه، لا الفيديو ولا الكلمات ولا أسماء الأماكن.</p>",
  'head': "ريل أو منشور تشاركه",
  'p1': "هذا هو الجزء الوحيد من Wren الذي يرسل شيئًا اخترته إلى خادم يديره Wren، ولا يحدث إلا عند مشاركة أو لصق رابط ريل أو منشور. لا يستطيع Wren قراءته على الهاتف: فورقة المشاركة تسلّم عنوان ويب ولا تسلّم الفيديو أبدًا.",
  'p2': "<strong>ما يُرسَل هو الرابط وإثبات أنك اشتريت الميزة.</strong> لا شيء غير ذلك — لا اسم ولا بريد إلكتروني ولا موقع ولا لقطات شاشة. يجلب الخادم المنشور، ويجعل نموذجًا لغويًا يقرأ منه أسماء الأماكن، ويعيد <em>الأسماء</em> إلى هاتفك، ويتلف الباقي. <strong>لا يُخزَّن أي شيء عن المنشور: لا العنوان ولا الفيديو ولا التعليق ولا الأسماء التي وُجدت.</strong> يُكتب سطر واحد فقط، ويذكر أن عملية شراء واحدة استهلكت وحدة من حصتها الشهرية.",
  'p3': "تشارك في تلك اللحظة شركتان أخريان ولا تعرف أي منهما من أنت: خدمة تُدعى ScrapeCreators تجلب المنشور من المنصة التي تستضيفه، وVertex AI من Google تشغّل النموذج الذي يقرأه. تذكر Google أن البيانات المرسلة إلى Vertex AI لا تُستخدم لتدريب نماذجها. ليس Wren تابعًا لإنستغرام أو تيك توك أو يوتيوب، ولا يطلب سوى منشور اخترت مشاركته.",
 },
 'hi': {
  'short': "<p><strong>ऐप</strong> में कोई खाता नहीं है और कोई विश्लेषण नहीं। आपके स्क्रीनशॉट और आपके द्वारा आयात की गई कोई भी फ़ाइल आपके फ़ोन पर ही पढ़ी जाती है और कभी अपलोड नहीं होती। Wren के अपने सर्वर तक सिर्फ़ दो चीज़ें पहुँचती हैं, और वह भी तभी जब आप कहें: एक नि:शुल्क एक्सेस कोड, यदि आपको दिया गया हो और आप उसे दर्ज करें; और किसी रील या पोस्ट का लिंक, यदि आप उसे Wren से पढ़वाने के लिए शेयर करें। वह पोस्ट लाई जाती है, पढ़ी जाती है और हटा दी जाती है — उसमें से कुछ भी नहीं रखा जाता, न वीडियो, न शब्द, न जगहों के नाम।</p>",
  'head': "आपके द्वारा शेयर की गई रील या पोस्ट",
  'p1': "यह Wren का एकमात्र हिस्सा है जो आपकी चुनी हुई कोई चीज़ Wren के अपने सर्वर पर भेजता है, और यह तभी होता है जब आप किसी रील या पोस्ट का लिंक शेयर या पेस्ट करते हैं। Wren उसे फ़ोन पर नहीं पढ़ सकता: शेयर शीट एक वेब पता सौंपती है, वीडियो कभी नहीं।",
  'p2': "<strong>जो भेजा जाता है वह है लिंक, और इसका प्रमाण कि आपने यह सुविधा खरीदी है।</strong> और कुछ नहीं — न नाम, न ईमेल, न स्थान, न स्क्रीनशॉट। सर्वर उस पोस्ट को लाता है, एक भाषा मॉडल से उसमें से जगहों के नाम पढ़वाता है, <em>नाम</em> आपके फ़ोन पर लौटाता है और बाकी हटा देता है। <strong>पोस्ट के बारे में कुछ भी संग्रहीत नहीं होता: न पता, न वीडियो, न कैप्शन, न मिले हुए नाम।</strong> केवल एक पंक्ति लिखी जाती है, और वह इतना ही कहती है कि एक खरीद ने अपनी मासिक सीमा की एक इकाई खर्च की।",
  'p3': "उस क्षण दो और कंपनियाँ शामिल होती हैं और उनमें से कोई नहीं जानती कि आप कौन हैं: ScrapeCreators नामक एक सेवा उस पोस्ट को उस मंच से लाती है जो उसे होस्ट करता है, और Google का Vertex AI उसे पढ़ने वाला मॉडल चलाता है। Google बताता है कि Vertex AI को भेजा गया डेटा उसके मॉडलों को प्रशिक्षित करने के लिए उपयोग नहीं होता। Wren का Instagram, TikTok या YouTube से कोई संबंध नहीं है, और वह केवल वही पोस्ट माँगता है जिसे आपने शेयर करना चुना है।",
 },
 'bn': {
  'short': "<p><strong>অ্যাপটির</strong> কোনও অ্যাকাউন্ট নেই, কোনও অ্যানালিটিক্সও নেই। আপনার স্ক্রিনশট আর আপনার আমদানি করা যেকোনও ফাইল আপনার ফোনেই পড়া হয় এবং কখনও আপলোড হয় না। Wren-এর নিজস্ব সার্ভারে কেবল দুটো জিনিস পৌঁছয়, আর তা-ও কেবল আপনি চাইলে: একটা বিনামূল্যের অ্যাক্সেস কোড, যদি আপনাকে দেওয়া হয়ে থাকে আর আপনি সেটা দেন; আর কোনও রিল বা পোস্টের লিঙ্ক, যদি আপনি Wren-কে পড়ানোর জন্য শেয়ার করেন। সেই পোস্টটা আনা হয়, পড়া হয়, তারপর ফেলে দেওয়া হয় — তার কিছুই রাখা হয় না, ভিডিও নয়, কথাগুলো নয়, জায়গার নামও নয়।</p>",
  'head': "আপনার শেয়ার করা রিল বা পোস্ট",
  'p1': "এটাই Wren-এর একমাত্র অংশ যা আপনার বেছে নেওয়া কিছু Wren-এর নিজস্ব সার্ভারে পাঠায়, আর সেটা ঘটে কেবল তখনই যখন আপনি কোনও রিল বা পোস্টের লিঙ্ক শেয়ার বা পেস্ট করেন। Wren সেটা ফোনে পড়তে পারে না: শেয়ার শিট একটা ওয়েব ঠিকানা দেয়, কখনও ভিডিও নয়।",
  'p2': "<strong>যা পাঠানো হয় তা হল লিঙ্ক, আর আপনি যে ফিচারটা কিনেছেন তার প্রমাণ।</strong> আর কিছু নয় — নাম নয়, ইমেল নয়, অবস্থান নয়, স্ক্রিনশট নয়। সার্ভার পোস্টটা আনে, একটা ভাষা মডেলকে দিয়ে তার থেকে জায়গার নাম পড়ায়, <em>নামগুলো</em> আপনার ফোনে ফেরত পাঠায়, বাকিটা ফেলে দেয়। <strong>পোস্ট নিয়ে কিছুই জমা রাখা হয় না: ঠিকানা নয়, ভিডিও নয়, ক্যাপশন নয়, খুঁজে পাওয়া নামগুলোও নয়।</strong> একটাই সারি লেখা হয়, আর তাতে শুধু থাকে যে একটা কেনাকাটা তার মাসিক কোটার একটা একক খরচ করেছে।",
  'p3': "ওই মুহূর্তে আরও দুটো কোম্পানি জড়িত থাকে আর কেউই জানে না আপনি কে: ScrapeCreators নামে একটা পরিষেবা পোস্টটা যে প্ল্যাটফর্মে আছে সেখান থেকে আনে, আর Google-এর Vertex AI সেটা পড়ার মডেলটা চালায়। Google জানায় যে Vertex AI-তে পাঠানো ডেটা তাদের মডেল প্রশিক্ষণে ব্যবহার হয় না। Wren-এর সঙ্গে Instagram, TikTok বা YouTube-এর কোনও সম্পর্ক নেই, আর ও কেবল সেই পোস্টটাই চায় যেটা আপনি শেয়ার করতে বেছে নিয়েছেন।",
 },
 'mr': {
  'short': "<p><strong>या अॅपमध्ये</strong> खाती नाहीत आणि विश्लेषणही नाही. तुमचे स्क्रीनशॉट आणि तुम्ही आयात केलेली कोणतीही फाइल तुमच्या फोनवरच वाचली जाते आणि कधीच अपलोड होत नाही. Wren च्या स्वतःच्या सर्व्हरपर्यंत फक्त दोन गोष्टी पोहोचतात, आणि त्याही तुम्ही सांगाल तेव्हाच: मोफत प्रवेश कोड, जर तुम्हाला दिला असेल आणि तुम्ही तो टाकला असेल; आणि एखाद्या रील किंवा पोस्टची लिंक, जर तुम्ही ती Wren ला वाचायला दिली असेल. ती पोस्ट आणली जाते, वाचली जाते आणि टाकून दिली जाते — तिच्यातलं काहीही ठेवलं जात नाही, व्हिडिओ नाही, शब्द नाहीत, ठिकाणांची नावंही नाहीत.</p>",
  'head': "तुम्ही शेअर केलेली रील किंवा पोस्ट",
  'p1': "Wren चा हा एकमेव भाग आहे जो तुम्ही निवडलेलं काहीतरी Wren च्या स्वतःच्या सर्व्हरवर पाठवतो, आणि तेही फक्त तुम्ही एखाद्या रील किंवा पोस्टची लिंक शेअर किंवा पेस्ट करता तेव्हा. Wren ती फोनवर वाचू शकत नाही: शेअर शीट एक वेब पत्ता देते, व्हिडिओ कधीच नाही.",
  'p2': "<strong>जे पाठवलं जातं ते म्हणजे लिंक, आणि तुम्ही ते वैशिष्ट्य विकत घेतल्याचा पुरावा.</strong> दुसरं काहीही नाही — नाव नाही, ईमेल नाही, स्थान नाही, स्क्रीनशॉट नाही. सर्व्हर ती पोस्ट आणतो, एका भाषा मॉडेलकडून तिच्यातली ठिकाणांची नावं वाचून घेतो, <em>नावं</em> तुमच्या फोनवर परत पाठवतो आणि बाकीचं टाकून देतो. <strong>पोस्टबद्दल काहीही साठवलं जात नाही: पत्ता नाही, व्हिडिओ नाही, मजकूर नाही, सापडलेली नावंही नाहीत.</strong> फक्त एकच ओळ लिहिली जाते, आणि ती इतकंच सांगते की एका खरेदीने तिच्या मासिक मर्यादेतलं एक एकक वापरलं.",
  'p3': "त्या क्षणी आणखी दोन कंपन्या सहभागी असतात आणि त्यांतल्या कोणालाही तुम्ही कोण आहात हे कळत नाही: ScrapeCreators नावाची सेवा ती पोस्ट जिथे आहे त्या प्लॅटफॉर्मवरून आणते, आणि Google चं Vertex AI ती वाचणारं मॉडेल चालवतं. Google सांगतं की Vertex AI ला पाठवलेला डेटा त्यांची मॉडेल्स प्रशिक्षित करण्यासाठी वापरला जात नाही. Wren चा Instagram, TikTok किंवा YouTube शी काही संबंध नाही, आणि तो फक्त तीच पोस्ट मागतो जी तुम्ही शेअर करायचं ठरवलं आहे.",
 },
 'te': {
  'short': "<p><strong>యాప్</strong>‌కు ఖాతాలు లేవు, విశ్లేషణలూ లేవు. మీ స్క్రీన్‌షాట్‌లు, మీరు దిగుమతి చేసే ఏ ఫైలైనా మీ ఫోన్‌లోనే చదవబడతాయి, ఎప్పుడూ అప్‌లోడ్ కావు. Wren సొంత సర్వర్‌కు కేవలం రెండు విషయాలే చేరతాయి, అదీ మీరు అడిగినప్పుడే: ఉచిత యాక్సెస్ కోడ్, మీకు ఇచ్చి ఉంటే మరియు మీరు దాన్ని నమోదు చేస్తే; మరియు ఒక రీల్ లేదా పోస్ట్ లింక్, Wren చదవడానికి మీరు పంచుకుంటే. ఆ పోస్ట్ తెచ్చి, చదివి, పారేయబడుతుంది — దానిలోంచి ఏదీ ఉంచబడదు, వీడియో కాదు, మాటలు కాదు, ప్రదేశాల పేర్లూ కాదు.</p>",
  'head': "మీరు పంచుకున్న రీల్ లేదా పోస్ట్",
  'p1': "మీరు ఎంచుకున్న దాన్ని Wren సొంత సర్వర్‌కు పంపే ఏకైక భాగం ఇదే, అదీ మీరు ఒక రీల్ లేదా పోస్ట్ లింక్‌ను పంచుకున్నప్పుడు లేదా అతికించినప్పుడు మాత్రమే. Wren దాన్ని ఫోన్‌లో చదవలేదు: షేర్ షీట్ ఒక వెబ్ చిరునామాను అందిస్తుంది, వీడియోను ఎప్పుడూ కాదు.",
  'p2': "<strong>పంపబడేది ఆ లింక్, మరియు మీరు ఆ ఫీచర్‌ను కొన్నారని రుజువు.</strong> ఇంకేమీ కాదు — పేరు కాదు, ఇమెయిల్ కాదు, స్థానం కాదు, స్క్రీన్‌షాట్‌లు కాదు. సర్వర్ ఆ పోస్ట్‌ను తెచ్చి, ఒక భాషా నమూనాతో అందులోని ప్రదేశాల పేర్లను చదివించి, <em>పేర్లను</em> మీ ఫోన్‌కు తిరిగి పంపి, మిగిలినది పారేస్తుంది. <strong>పోస్ట్ గురించి ఏదీ నిల్వ చేయబడదు: చిరునామా కాదు, వీడియో కాదు, శీర్షిక కాదు, దొరికిన పేర్లూ కాదు.</strong> ఒకే ఒక వరుస రాయబడుతుంది, అది ఒక కొనుగోలు తన నెలవారీ కోటాలో ఒక యూనిట్‌ను వాడిందని మాత్రమే చెబుతుంది.",
  'p3': "ఆ క్షణంలో మరో రెండు కంపెనీలు పాలుపంచుకుంటాయి, వాటిలో ఏదీ మీరు ఎవరో తెలుసుకోదు: ScrapeCreators అనే సేవ ఆ పోస్ట్‌ను దాన్ని హోస్ట్ చేసే వేదిక నుంచి తెస్తుంది, Google Vertex AI దాన్ని చదివే నమూనాను నడుపుతుంది. Vertex AI‌కు పంపిన డేటా తమ నమూనాల శిక్షణకు వాడబడదని Google తెలుపుతుంది. Wren‌కు Instagram, TikTok లేదా YouTube‌తో సంబంధం లేదు, మరియు మీరు పంచుకోవాలని ఎంచుకున్న పోస్ట్‌ను మాత్రమే అది అడుగుతుంది.",
 },
 'ur': {
  'short': "<p><strong>ایپ</strong> میں کوئی اکاؤنٹ نہیں اور کوئی تجزیہ نہیں۔ آپ کے اسکرین شاٹ اور آپ کی درآمد کردہ کوئی بھی فائل آپ ہی کے فون پر پڑھی جاتی ہے اور کبھی اپ لوڈ نہیں ہوتی۔ Wren کے اپنے سرور تک صرف دو چیزیں پہنچتی ہیں، اور وہ بھی تبھی جب آپ کہیں: ایک مفت رسائی کوڈ، اگر آپ کو دیا گیا ہو اور آپ اسے درج کریں؛ اور کسی ریل یا پوسٹ کا لنک، اگر آپ اسے Wren سے پڑھوانے کے لیے شیئر کریں۔ وہ پوسٹ لائی جاتی ہے، پڑھی جاتی ہے، پھر ہٹا دی جاتی ہے — اس میں سے کچھ بھی نہیں رکھا جاتا، نہ ویڈیو، نہ الفاظ، نہ مقامات کے نام۔</p>",
  'head': "آپ کی شیئر کی گئی ریل یا پوسٹ",
  'p1': "یہ Wren کا واحد حصہ ہے جو آپ کی منتخب کردہ کوئی چیز Wren کے اپنے سرور کو بھیجتا ہے، اور یہ صرف تب ہوتا ہے جب آپ کسی ریل یا پوسٹ کا لنک شیئر یا چسپاں کریں۔ Wren اسے فون پر نہیں پڑھ سکتا: شیئر شیٹ ایک ویب پتہ دیتی ہے، ویڈیو کبھی نہیں۔",
  'p2': "<strong>جو بھیجا جاتا ہے وہ لنک ہے، اور اس بات کا ثبوت کہ آپ نے یہ خصوصیت خریدی ہے۔</strong> اور کچھ نہیں — نہ نام، نہ ای میل، نہ مقام، نہ اسکرین شاٹ۔ سرور وہ پوسٹ لاتا ہے، ایک لسانی ماڈل سے اس میں سے مقامات کے نام پڑھواتا ہے، <em>نام</em> آپ کے فون کو واپس بھیجتا ہے اور باقی ہٹا دیتا ہے۔ <strong>پوسٹ کے بارے میں کچھ بھی محفوظ نہیں کیا جاتا: نہ پتہ، نہ ویڈیو، نہ کیپشن، نہ ملے ہوئے نام۔</strong> صرف ایک سطر لکھی جاتی ہے، اور وہ بس اتنا کہتی ہے کہ ایک خریداری نے اپنے ماہانہ کوٹے کی ایک اکائی خرچ کی۔",
  'p3': "اس لمحے دو اور کمپنیاں شامل ہوتی ہیں اور ان میں سے کوئی نہیں جانتی کہ آپ کون ہیں: ScrapeCreators نامی ایک سروس وہ پوسٹ اُس پلیٹ فارم سے لاتی ہے جو اسے میزبانی دیتا ہے، اور Google کا Vertex AI اسے پڑھنے والا ماڈل چلاتا ہے۔ Google کہتا ہے کہ Vertex AI کو بھیجا گیا ڈیٹا اس کے ماڈلز کی تربیت کے لیے استعمال نہیں ہوتا۔ Wren کا Instagram، TikTok یا YouTube سے کوئی تعلق نہیں، اور وہ صرف وہی پوسٹ مانگتا ہے جسے آپ نے شیئر کرنا چنا ہے۔",
 },
}


def rewrite(lang, write):
    path = os.path.join(HERE, lang, 'privacy.html')
    lines = io.open(path, encoding='utf-8').read().split('\n')
    # These pages end WITHOUT a trailing newline, so the split yields
    # exactly the line count and no empty tail. They are written back the
    # same way, or every page grows a blank line on each run.
    if len(lines) != LINES:
        return f'{lang}: {len(lines)} lines, expected {LINES} — skipped'
    short = lines[SHORT_VERSION - 1]
    if not short.strip().startswith('<p><strong>'):
        return f'{lang}: line {SHORT_VERSION} is not the short version — skipped'
    if lines[AFTER_SCREENSHOTS - 1].strip() != '</section>':
        return (f'{lang}: line {AFTER_SCREENSHOTS} is '
                f'{lines[AFTER_SCREENSHOTS - 1].strip()!r}, not </section> — skipped')

    t = TEXT[lang]
    lines[SHORT_VERSION - 1] = '    ' + t['short']
    section = ['', '', '', '  <section>', '', '',
               f"    <h2>{t['head']}</h2>", '', '',
               f"    <p>{t['p1']}</p>", '', '',
               f"    <p>{t['p2']}</p>", '', '',
               f"    <p>{t['p3']}</p>", '', '',
               '  </section>']
    lines[AFTER_SCREENSHOTS:AFTER_SCREENSHOTS] = section
    if write:
        io.open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
    return f'{lang}: short version replaced, section added ({len(lines)} lines)'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except (AttributeError, OSError):
        pass
    for lang in sorted(TEXT):
        print(rewrite(lang, args.write))
    if not args.write:
        print('\nnothing written — run with --write')


if __name__ == '__main__':
    main()
