# Sakviro onboarding ir bibliotekos sinchronizavimas

Projektas, laukia patvirtinimo. 2026-11-09.

## Tikslas

Pakeisti onboarding taip, kad žmogus atskirai pasirinktų transkripcijos ir Assistant nustatymus, suprastų bibliotekos vietą ir galėtų aiškiai įjungti sinchronizavimą. Sakviro neturi atskiro cloud serverio, paskyros ar prenumeratos. Dabartinis Cloud preset parenka AI tiekėjus, o naujoje eigoje siūloma pašalinti šį painų pasirinkimų rinkinį ir debesijos pažadą.

Patvirtintas poreikis yra visa biblioteka sinchronizuojama tarp kompiuterių. Sinchronizavimas yra pasirenkamas, numatytasis saugojimas lieka šiame Mac. Šiame dokumente pateikti transporto, duomenų ir konfliktų sprendimo būdai yra architektūros pasiūlymai, kol jie bus patvirtinti.

## Ribos

- Vietinė biblioteka ir sinchronizavimas į OneDrive, Google Drive arba pasirinktą S3 suderinamą objektų saugyklą.
- Rclone siūlomas kaip vienas bendras failų transportas. Sakviro valdo bibliotekos versijas ir konfliktus.
- Esamos AI integracijos, jų modeliai ir Auto pasirinkimas lieka nepriklausomi nuo bibliotekos vietos.
- Esami naudotojai, kurių onboarding baigtas, lieka onboardinti. Trumpas Assistant turas nereikalauja rinktis bibliotekos saugyklos.

Pasiūlymo ribos yra Sakviro serverio, paskyrų ar prenumeratų neturintis modelis, vieno naudotojo biblioteka, atskira DB kiekviename Mac ir be biometrinių balso duomenų sinchronizavimo.

## Onboarding

Pagrindinė eiga. Po esamų Pasveikinimo ir Leidimų žingsnių rodomi nepriklausomi Transkripcijos ir Assistant pasirinkimai, tada vienas Bibliotekos ir saugyklos žingsnis.

```text
Pasveikinimas → Leidimai → Transkripcija → Assistant → Biblioteka ir saugykla
→ Pasirenkama AI programų integracija → Baigta
```

Transkripcijos žingsnyje pasirenkamas esamas kalbos atpažinimo tiekėjas ir jo nustatymai. Assistant žingsnyje pasirenkamas esamas AI tiekėjas, modelis arba Auto, ir Assistant įjungimas. Žingsniai nepakeičia vartotojo pasirinkimo iš anksto sugrupuotu Private, Balanced ar Cloud keliu.

Dabartinis „Cloud“ preset parenka Claude ir Deepgram su naudotojo API raktais. Tai AI paslaugų kombinacija, atskirai nuo bibliotekos saugyklos. Viešieji `ProviderModelSettings`, `ProviderAutoModelSettings` ir `CLIProviderSettings` yra pakartotinai naudojami nustatymų valdikliai. Onboarding lange naudojami tik konkretūs valdikliai.

Bibliotekos ir saugyklos žingsnyje parodoma duomenų apimtis, vietinės išimtys bei pasirinkimai šiame Mac, OneDrive, Google Drive ir S3 suderinamai saugyklai. Vietinis pasirinkimas užbaigia žingsnį. Pasirinkus sinchronizavimą, sąlyginiai subžingsniai pateikia OneDrive ar Drive Connect, S3 kredencialus, bibliotekos sukūrimą arba prisijungimą ir apimties peržiūrą. Rclone remote siūlomas pažengusiesiems ir kūrimo bandymams.

Prieš įjungiant sinchronizavimą peržiūrimi įrašų skaičiai, kategorijos, privatumo išimtys ir paskirties vieta. Naudotojas pasirenka kurti biblioteką ar prisijungti prie esamos. Prisijungimas sujungia vietinę ir nuotolinę bibliotekas, išsaugant tapatybes bei konfliktus.

Senos Private, Balanced, Cloud, CLI ir later reikšmės bei pavadinti ar skaitiniai žingsniai perkeliami į galiojančius naujos eigos žingsnius. Išsaugomi tikrieji provider, modelio ir kitų nustatymų duomenys. Cloud kelio vardas pats savaime nereiškia debesijos backend. Nereikia priverstinai atnaujinti jau baigto onboarding.

## Duomenų apimtis

Siūloma sinchronizuojamų duomenų apimtis

- Visa versioned durable schema apima susitikimus, transkriptus, įžvalgas, pastabas, About, ataskaitas ir ankstesnes ataskaitų versijas, šablonų kopijas, timeline, bookmarks, sutikimus, usage, dalyvių vardus, nudge ir follow-up duomenis bei kitą naudotojo sukurtą bibliotekos metaduomenį.
- Užbaigti garso bei vaizdo įrašai, skambučių profiliai ir išsaugotos profilių versijos.
- Knowledge Base dokumentai, aplankai, šaltinio tekstas iš chunk įrašų ir taikymo profiliams sritys.
- Saugomi Ask pokalbiai, jei juose nėra privačios medžiagos.

Importuotas originalus Knowledge Base failas po apdorojimo neišsaugomas. Sinchronizuojamas dabartinis išsaugotas tekstas. Embedding ir paieškos indeksai atkuriami kiekviename Mac vietoje.

Privatumo ribos yra pasiūlymas išsaugoti dabartinį vietinio naudojimo sutikimą. Biometriniai balso embedding, apsaugoti susitikimai, apsaugotą turinį naudoję Ask pokalbiai ir tik lokaliems profiliams priskirti KB duomenys nepatenka į sinchronizavimą. Tai aiškiai parodoma onboarding peržiūroje. Naujų sutikimų balso embedding įkėlimui šiame pakeitime nesiūloma.

Lokaliai lieka runtime ir provider nustatymai, API raktai, macOS leidimai, vykdomieji failai, Python ar modelių keliai, žymės, atsisiuntimai, migracijų atsarginės kopijos ir dar nepatvirtinti profilių importai. API raktai saugomi Keychain.

Globalus `CloudGate` arba `onDeviceOnly` pristabdo naujus sinchronizavimo veiksmus. Jau įkelti objektai iš paskirties vietos atgal automatiškai neatšaukiami. Susitikimas su apsaugotu turiniu praleidžiamas. Ask pokalbis praleidžiamas, jei panaudojo `usedPrivate`, saugomą scope, reference arba cituotą šaltinį. `onDeviceOnly` profiliai ir tik privatiems profiliams skirti KB duomenys taip pat praleidžiami. Kiti KB scope nėra leidimas juos kelti. Peržiūra parodo įtrauktų profilių ir KB skaičių bei išimtis.

Po pirmo įkėlimo privatumo pakeitimas pirmiausia lokaliai įrašo durable privacy flag ir užblokuoja to objekto bei iš jo kilusių protected chat įkėlimą. Iš outbox atšaukiami arba perfiltruojami jau paruošti vieši snapshot. Tada withdrawal metaduomenys įrašomi į eilę ir publikuojami ryšiui atsiradus. Vietinė privati kopija lieka šiame Mac. Kiti Mac withdrawal pritaiko prisijungę ir sustabdo to turinio publikavimą. Jautrus payload ir nebereikalingi bendri blob įrašomi į purge eilę, o revocation statusas lieka pending iki patvirtinimo. Bendras blob šalinamas tik kai jį naudoti leidžiančių objektų nebelieka.

Nuotolinė konfigūracija neišplečia šiame Mac leidžiamo turinio. Pirmo sync peržiūra parodo dabartines `audioDays` ir `meetingDays` taisykles, o jų taikymas visoje bibliotekoje reikalauja aiškaus patvirtinimo. Patvirtinta bibliotekos retention taisyklė tampa versioned bibliotekos metaduomenimis ir vienoda visuose Mac. Ji sukuria tombstone sinchronizuotiems objektams. Nesinchronizuojamai apsaugotai medžiagai toliau taikomos dabartinio įrenginio taisyklės. Medijos retention atskiriamas nuo susitikimo ištrynimo.

## Bibliotekos duomenų modelis

Siūlomas versijuotas portable envelope turi bibliotekos, objekto tipo, stabilaus objekto ID, versijos ID, tėvinių versijų ID, turinio ir medijos metaduomenis. Kiekvienas Mac turi atskirą `writerID`. Priedai dedami į turinio hash pagrindu sudarytus kelius, o manifesto failo vardas turi atitikti SHA-256 turinį. Bendrai redaguojamo `head` failo nėra.

Meeting ir jo transcript bei insight vaikai publikuojami kaip vienas užbaigtas agregatas, kad kitas Mac negautų pusinio susitikimo. Neužbaigtas įrašymas, importas ar ataskaitos užduotis neskelbiama. Naujesnė ataskaita sukuria kitą versiją. Kiti objektai gali turėti savas versijas pagal jų esamus tipus.

Sinchronizuojamas pilnas Sakviro portable profilis, jo stabilus `sharedID`, istorija ir nuorodos. `.parrotprofile` share exporter gali praleisti `sharedID` bei istoriją, o importer gali priskirti naują ID, todėl šis kelias nėra pilnas sync serializer. Juo dalijamasi validacija ir Codable laukų formomis. Previous meeting, report, chat ir profilių nuorodos išlaikomos arba pažymimos neišspręstomis, jei nuorodos objektas neįtrauktas. KB profilių scope remiasi `sharedID`. KB dokumento pakeitimas išlaiko stabilų ID, o migracija suderinama su esamu indeksu. Chunk ownership seka ID.

Kiekvienas Mac laiko savo SwiftData DB ir KB bei Chats JSON saugyklas. Sinchronizuojamas portable objektų turinys, vietinių media failų keliai atkuriami priėmimo metu. Durable apply journal įrašo SwiftData, KB ir Chats taikymo fazes, kad paleidimas po gedimo galėtų tęsti arba saugiai pakartoti commit. Prieš pull/apply užfiksuojama vietinė bazinė versija ir objekto hash arba generation. Jei naudotojas tuo metu pakeitė objektą, remote versija pritaikoma kaip konfliktas, vietinis pakeitimas išsaugomas. Sinchronizuotas statusas rodomas po lokalaus commit ir patvirtinto nuotolinio įkėlimo.

## Transportas ir privatumas

Sinchronizavimo servisas naudoja esamus objektų saugojimo savininkus, vieną serializuotą eilę bibliotekai ir išliekančius vietinius outbox bei inbox. Pakeitimai registruojami per atsakingų saugyklų save ir delete vietas arba tikslų turinio palyginimą su paskutine sėkminga versija. Galutinis pasirinkimas turi aprėpti įprastus keitimo, trynimo ir autosave kelius.

Transportas įkelia nepakeičiamus versijų failus ir blob turinį. Pirmiausia perduodami bei patikrinami blob, tada manifestas. Retry naudoja tą patį stabilų objekto ID, versijos ID ir turinio baitus. Gavėjas tikrina hash, schemą, ID, priklausomybes, dydžius, objektų skaičių ir kelių saugumą. Trūkstamos priklausomybės lieka pending iki kito bandymo. Sąrašų vėlavimas sprendžiamas kartotiniais nuskaitymais, dingęs failas nelaikomas ištrynimu. Vienodo UUID ir hash įrašai sujungiami tik patikrinus turinį. Dviprasmiškas bibliotekos katalogas sukelia aiškią klaidą. Nepalaikoma versija rodoma kaip nesuderinama ir nieko neperrašo.

Naudojamas įdiegtas ir pasirašytas `HostHelper` / `HostCLIService` vykdymo kraštas. Dabartinė bendra CLI operacija turi 300 sekundžių timeout, fiksuotą environment ir AI klaidų pateikimą. Jai pritaikoma konkreti rclone operacija su ilgo perdavimo, atšaukimo, saugaus config perdavimo ir ribotų logų palaikymu. Jautrūs duomenys nekeliauja argv ar loguose.

Atskirai pasirašytoje programoje rclone config šifruojamas, jo šifravimo paslaptis laikoma Keychain, o config perduodamas child procesui saugiu kanalu. Remote payload apsauga remiasi naudotojo paskyra ir pasirinktos saugyklos transportu. Esamas `crypt` remote išlaiko savo elgseną. Sakviro valdomas end-to-end content encryption į šį pakeitimą neįtrauktas.

Rclone v1.75.2 yra šiame Mac, o kitos instaliacijos gauna prisegtą, pasirašytą ir licencijuotą binary. `copy` / `copyto` naudojami failų perdavimui. FUSE, librclone ir atskiras daemonas neįtraukiami. Pirmoje versijoje OneDrive ir Google Drive turi įprastą Connect, o S3 pateikia kredencialų laukus. Google Drive Connect priklauso nuo Sakviro OAuth app registracijos, kurią turi sukurti registraciją valdantis paskyros savininkas. OneDrive gali naudoti bendrą rclone OAuth palaikymą arba Sakviro registraciją. Registruotų app vieši client ID pateikiami build konfigūracijoje, Sakviro serverio tam nereikia. Rclone remote lieka pažengusiųjų kūrimo ir bandymų keliu. Rclone bendro kliento ID atsisakoma 2026 m., bet savo ID dar nėra besąlyginė sąlyga.

## Konfliktai ir ištrynimai

Konfliktas yra tada, kai nė viena versijos galva nėra kitos protėvis. Visos tokios nepalyginamos galvos ir jų medija išlaikomos. Pagrindinė peržiūros versija deterministiškai parenkama pagal versijos ID, likusios matomos. Laikrodžiai tinka tik atvaizdavimui. Sprendimas sukuria versiją su visomis išspręstomis galvomis kaip tėvais.

Ištrynimas sukuria tombstone, apimantį žinomas ankstesnes versijas. Vienalaikis redagavimas ir ištrynimas palieka nepalyginamas galvas, todėl abu variantai lieka konflikte. Objektas vietoje šalinamas tik tada, kai tombstone patikimai įrašytas į sinchronizavimo žurnalą. Pakartotinis bandymas negali atkurti pasenusio objekto.

Įprastas ištrynimas paslepia įrašą aktyvioje bibliotekoje kituose Mac per kitą sync. Įrenginys be ryšio pakeitimą pritaiko prisijungęs, todėl ištrynimas tarp offline Mac nėra momentinis. Turinys, versijos ir medija laikomi atkuriamoje šiukšlinėje 30 dienų nuo pradinio ištrynimo laiko. Retry termino nenustato iš naujo. Atkūrus per šį laiką sukuriama priežastinė versija, pakeičianti žinomą tombstone ir grąžinanti ryšius bei mediją.

Praėjus 30 dienų per artimiausią sync turinys galutinai pašalinamas iš nuotolinės saugyklos ir prisijungusių įrenginių. Įrenginiai be ryšio tai atlieka prisijungę. Tombstone ir priežastiniai metaduomenys išlieka, kad ištrintas turinys negrįžtų. Bendras blob šalinamas tik jei jis neturi aktyvių leidžiamų ar dar atkuriamų nuorodų. Vienalaikis redagavimas ir ištrynimas lieka konfliktu, išsaugant abu variantus.

Ši 30 dienų taisyklė taikoma įprastam naudotojo ištrynimui. Po įkėlimo atlikto privacy withdrawal fizinio purge terminas yra atskiras nepatvirtintas sprendimas, jis gali būti momentinis arba 30 dienų. Jis automatiškai nepaveldi įprasto ištrynimo atkūrimo lango.

## Patvirtinimo įrodymai prieš užbaigiant

- Esami `make test` ir `make` patikrinimai išlieka žali.
- Mažas sync harness su dviem nepriklausomomis vietinėmis bibliotekomis ir tikru rclone local backend patikrina kūrimą, keitimą, trynimą, vienalaikius pakeitimus, ištrynimo konfliktą, restartą, gedimą bei retry, dalinius manifestus ir mediją.
- Tikrinamos `sharedID` bei KB scope migracijos, apsaugotų Ask pokalbių ir voiceprint išimtys, retention ir vietinių media kelių atkūrimas.
- Sync testai patikrina ištrynimą ir atkūrimą 29 dieną su ryšių bei medijos grąžinimu, atskirą purge po 30 dienų nepakeitus pradinio termino retry metu, offline įrenginio prisijungimą po termino taip, kad ištrintas turinys negrįžtų, ir bendrų blob nuorodas iki paskutinio atkuriamo įrašo.
- UI snapshot įrodo naujos eigos atnaujinimą, onboarding tęsimą po uždarymo, senų būsenų migraciją, baigto onboarding išsaugojimą, AI provider bei modelio pasirinkimus, Auto, saugyklos būseną ir konfliktų peržiūrą.
- Patikrintas sandboxed app vykdomas pasirašytas helper. Tikras OneDrive, Google Drive, S3 ir dviejų Mac patikrinimas atliekamas tik su aiškiai sukonfigūruota bandomąja paskyra bei paskirties vieta. Vietinis transporto testas nėra realaus provider patvirtinimas.

## Siūlomi patvirtinti sprendimai

Prieš įgyvendinimą patvirtinti šią apimtį

- Pagrindinis onboarding atskiria transkripciją, Assistant ir bibliotekos saugyklą bei pašalina Private, Balanced ir Cloud bundlus bei su jais susietą cloud pažadą.
- Visa išvardyta ilgalaikė biblioteka sinchronizuojama, o API raktai, leidimai, vykdomieji failai, vietiniai indeksai ir biometriniai balso embedding lieka lokaliai.
- Vietinis pasirinkimas, OneDrive ir Google Drive Connect bei S3 kredencialų laukų palaikymas yra pirmos versijos apimtis. Sakviro Google Drive OAuth app registracija yra išorinė išleidimo prielaida. Rclone remote skirtas pažengusiųjų kūrimo ir bandymų keliui.
- Įprastas ištrynimas paslepia aktyvų įrašą kituose įrenginiuose per kitą sync, o turinys atkuriamas 30 dienų nuo pradinio ištrynimo. Po šio termino turinys pašalinamas per kitą sync, o tombstone apsaugo nuo ištrinto turinio grąžinimo. Privacy withdrawal purge terminas lieka atskiras sprendimas.

## Šaltiniai kode ir dokumentacijoje

- [Esama onboarding eiga](../../../Parrot/Views/OnboardingView.swift), [Assistant kelio presetai](../../../Parrot/Views/Onboarding/CopilotPathStep.swift), [onboarding būsena](../../../Parrot/Views/Onboarding/OnboardingModel.swift), [senų žingsnių migracija](../../../Parrot/Models/OnboardingFlow.swift), [provider pasirinkimų nustatymai](../../../Parrot/Services/CopilotSetupState.swift), [provider valdikliai](../../../Parrot/Views/CLIProviderSettings.swift).
- [CloudGate](../../../Parrot/Services/CloudGate.swift), [susitikimas](../../../Parrot/Models/Meeting.swift), [profilis](../../../Parrot/Models/CallProfile.swift), [profilio saugykla](../../../Parrot/Services/ProfileStore.swift), [KB](../../../Parrot/Services/KnowledgeBaseService.swift), [Ask pokalbiai](../../../Parrot/Services/AskChatStore.swift), [retention](../../../Parrot/Services/Retention.swift), [helper klientas](../../../Parrot/Services/HostHelperClient.swift).
- [Rclone Google Drive OAuth](https://rclone.org/drive/#making-your-own-client-id), [copy komanda](https://rclone.org/commands/rclone_copy/), [immutable failai](https://rclone.org/docs/#immutable), [Move apribojimai](https://rclone.org/overview/#move), [dublikatai Drive](https://rclone.org/drive/#duplicated-files), [config šifravimas](https://rclone.org/docs/#configuration-encryption), [bisync](https://rclone.org/bisync/).

Šiuo etapu parengtas tik projektavimo aprašas. Produkto kodas ir vykdymo patikros priklauso įgyvendinimui.
