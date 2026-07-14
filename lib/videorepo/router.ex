defmodule Videorepo.Router do
  @moduledoc """
  Repo de videos: subida por web, importacion desde YouTube (descarga + transcode
  a H.264/AAC) y serving HTTP con Range (reproduccion resumible para la TV).
  """
  use Plug.Router
  require Logger

  plug Plug.Logger
  plug :match

  # read_length chico = lecturas frecuentes (evita cortes en subidas lentas por WiFi);
  # read_timeout amplio para archivos grandes.
  plug Plug.Parsers,
    parsers: [:multipart, :urlencoded],
    length: 50_000_000_000,
    read_length: 256_000,
    read_timeout: 120_000

  plug :dispatch

  defp dir, do: Application.get_env(:videorepo, :video_dir, "/data/videos")

  # ---------- rutas ----------

  get "/health", do: send_resp(conn, 200, "ok")

  get "/" do
    conn |> put_resp_content_type("text/html") |> send_resp(200, page())
  end

  get "/api/videos" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(list_videos()))
  end

  get "/api/jobs" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Videorepo.Jobs.all()))
  end

  # Importar desde YouTube: descarga + transcode a H.264/AAC en background
  post "/youtube" do
    url = conn.params["url"]

    if is_binary(url) and String.contains?(url, "http") do
      id = Videorepo.Converter.start(String.trim(url), dir())
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, id: id}))
    else
      send_resp(conn, 400, "url invalida")
    end
  end

  post "/upload" do
    case conn.params["file"] do
      %Plug.Upload{path: tmp, filename: name} ->
        safe = safe_name(name)
        dest = Path.join(dir(), safe)
        File.mkdir_p!(dir())
        case File.rename(tmp, dest) do
          :ok -> :ok
          _ -> File.cp!(tmp, dest)
        end
        Logger.info("subido: #{safe} (#{File.stat!(dest).size} bytes)")
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, name: safe}))

      _ ->
        send_resp(conn, 400, "falta el campo 'file'")
    end
  end

  delete "/videos/:name" do
    with path when is_binary(path) <- safe_path(name), true <- File.exists?(path) do
      File.rm(path)
      send_resp(conn, 204, "")
    else
      _ -> send_resp(conn, 404, "no existe")
    end
  end

  get "/videos/:name", do: serve_file(conn, name)

  match _, do: send_resp(conn, 404, "not found")

  # ---------- serving con Range ----------

  defp serve_file(conn, name) do
    with path when is_binary(path) <- safe_path(name),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      conn =
        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_content_type(content_type(name))

      case get_req_header(conn, "range") do
        ["bytes=" <> spec] ->
          {offset, len} = parse_range(spec, size)

          conn
          |> put_resp_header("content-range", "bytes #{offset}-#{offset + len - 1}/#{size}")
          |> send_file(206, path, offset, len)

        _ ->
          send_file(conn, 200, path)
      end
    else
      _ -> send_resp(conn, 404, "no existe")
    end
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-") do
      [s, ""] -> start = String.to_integer(s); {start, size - start}
      ["", e] -> n = String.to_integer(e); {max(size - n, 0), min(n, size)}
      [s, e] -> start = String.to_integer(s); finish = min(String.to_integer(e), size - 1); {start, finish - start + 1}
      _ -> {0, size}
    end
  end

  # ---------- storage ----------

  defp list_videos do
    d = dir()

    case File.ls(d) do
      {:ok, files} ->
        files
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(fn f ->
          {:ok, st} = File.stat(Path.join(d, f), time: :posix)
          %{name: f, size: st.size, mtime: st.mtime}
        end)
        |> Enum.sort_by(& &1.mtime, :desc)

      _ ->
        []
    end
  end

  defp safe_name(name), do: name |> Path.basename() |> String.replace(~r/[^\w.\- ]/u, "_")

  defp safe_path(name) do
    base = Path.basename(name)
    if base in ["", ".", ".."], do: nil, else: Path.join(dir(), base)
  end

  defp content_type(name) do
    case name |> Path.extname() |> String.downcase() do
      ".mp4" -> "video/mp4"
      ".m4v" -> "video/mp4"
      ".mov" -> "video/quicktime"
      ".mkv" -> "video/x-matroska"
      ".webm" -> "video/webm"
      ".avi" -> "video/x-msvideo"
      ".ts" -> "video/mp2t"
      _ -> "application/octet-stream"
    end
  end

  # ---------- UI ----------

  defp page do
    """
    <!doctype html>
    <html lang="es"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Video Repo</title>
    <style>
      :root{color-scheme:dark}
      *{box-sizing:border-box}
      body{margin:0;font-family:system-ui,Segoe UI,Roboto,sans-serif;background:#0e1116;color:#e6edf3}
      header{padding:20px 24px;border-bottom:1px solid #21262d;display:flex;align-items:center;gap:12px}
      header h1{font-size:20px;margin:0}
      .wrap{max-width:900px;margin:0 auto;padding:24px}
      #drop{border:2px dashed #30363d;border-radius:12px;padding:30px;text-align:center;color:#9aa4b2;transition:.15s;cursor:pointer}
      #drop.hot{border-color:#2f81f7;background:#111a2b;color:#cdd9e5}
      #drop input{display:none}
      .bar{height:6px;background:#21262d;border-radius:4px;overflow:hidden;margin-top:14px;display:none}
      .bar > i{display:block;height:100%;width:0;background:#2f81f7;transition:width .1s}
      .yt{display:flex;gap:8px;margin:18px 0}
      .yt input{flex:1;background:#161b22;border:1px solid #30363d;border-radius:8px;color:#e6edf3;padding:11px 13px;font-size:14px}
      .yt button, .btn{background:#238636;color:#fff;border:1px solid #2ea043;border-radius:8px;padding:10px 16px;font-size:14px;cursor:pointer}
      #jobs .job{padding:9px 12px;border:1px solid #21262d;border-radius:8px;margin:6px 0;font-size:14px;color:#cdd9e5}
      #jobs .jt{color:#e6edf3}
      ul{list-style:none;padding:0;margin:20px 0 0}
      li{display:flex;align-items:center;gap:12px;padding:12px 14px;border:1px solid #21262d;border-radius:10px;margin-bottom:8px}
      li .n{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      li .s{color:#8b949e;font-size:13px;white-space:nowrap}
      button.sec,a.sec{background:#21262d;color:#e6edf3;border:1px solid #30363d;border-radius:8px;padding:7px 11px;font-size:13px;cursor:pointer;text-decoration:none}
      button.sec:hover,a.sec:hover{background:#30363d}
      .muted{color:#8b949e;font-size:13px;margin-top:10px}
      code{background:#161b22;border:1px solid #21262d;border-radius:6px;padding:2px 6px;font-size:12px}
    </style></head><body>
    <header>🎬 <h1>Video Repo</h1><span class="muted" style="margin:0">alta calidad · Elixir/OTP</span></header>
    <div class="wrap">
      <label id="drop">
        <input type="file" id="file" accept="video/*,audio/*" multiple>
        <div><b>Arrastra videos aqui</b> o hace click para elegir</div>
        <div class="muted">se guardan tal cual (sin recomprimir)</div>
        <div class="bar"><i></i></div>
      </label>

      <div class="yt">
        <input id="yturl" placeholder="🔗 pega un link de YouTube para descargar y convertir a MP4 (H.264/AAC)">
        <button onclick="startYt()">Descargar y convertir</button>
      </div>
      <div id="jobs"></div>

      <div class="muted">Reproducir en la TV: copia la URL de un video y lanzala con<br>
        <code>adb shell am start -n com.example.noblexcam/.MainActivity -e url "URL"</code></div>
      <ul id="list"></ul>
    </div>
    <script>
      const list=document.getElementById('list'), drop=document.getElementById('drop'),
            file=document.getElementById('file'), bar=document.querySelector('.bar'), fill=document.querySelector('.bar>i');
      const human=b=>{const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1024&&i<u.length-1){b/=1024;i++}return b.toFixed(1)+' '+u[i]};
      const esc=s=>String(s).replace(/[<>&]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;'}[c]));
      async function refresh(){
        let v=[]; try{ v=await (await fetch('/api/videos')).json(); }catch(e){}
        list.innerHTML = v.length ? '' : '<li class="muted">Todavia no hay videos.</li>';
        for(const it of v){
          const url=location.origin+'/videos/'+encodeURIComponent(it.name);
          const li=document.createElement('li');
          li.innerHTML=`<span class="n">${esc(it.name)}</span><span class="s">${human(it.size)}</span>`;
          const play=document.createElement('a');play.className='sec';play.textContent='▶';play.href=url;play.target='_blank';
          const copy=document.createElement('button');copy.className='sec';copy.textContent='📋 URL';
          copy.onclick=()=>{navigator.clipboard.writeText(url);copy.textContent='✓';setTimeout(()=>copy.textContent='📋 URL',1200)};
          const del=document.createElement('button');del.className='sec';del.textContent='🗑';
          del.onclick=async()=>{if(confirm('Borrar '+it.name+'?')){await fetch('/videos/'+encodeURIComponent(it.name),{method:'DELETE'});refresh()}};
          li.append(play,copy,del);list.append(li);
        }
      }
      const jobIcon=s=>s==='listo'?'✅':s==='error'?'❌':'⏳';
      async function pollJobs(){
        let jobs=[]; try{ jobs=await (await fetch('/api/jobs')).json(); }catch(e){}
        document.getElementById('jobs').innerHTML=jobs.map(j=>
          `<div class="job">${jobIcon(j.status)} <span class="jt">${esc(j.title)}</span> — <b>${esc(j.status)}</b>${j.error?' · '+esc(j.error):''}</div>`).join('');
        refresh();
        if(jobs.some(j=>j.status!=='listo'&&j.status!=='error')) setTimeout(pollJobs,2000);
      }
      async function startYt(){
        const el=document.getElementById('yturl'), u=el.value.trim(); if(!u) return;
        el.value='';
        try{ await fetch('/youtube',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'url='+encodeURIComponent(u)}); }catch(e){}
        pollJobs();
      }
      function uploadOne(f){return new Promise((res,rej)=>{
        const fd=new FormData();fd.append('file',f);
        const x=new XMLHttpRequest();x.open('POST','/upload');
        bar.style.display='block';
        x.upload.onprogress=e=>{if(e.lengthComputable)fill.style.width=(e.loaded/e.total*100)+'%'};
        x.onload=()=>{fill.style.width='0';bar.style.display='none';x.status<300?res():rej()};
        x.onerror=()=>rej();x.send(fd);
      })}
      async function handle(files){for(const f of files){try{await uploadOne(f)}catch(e){alert('Fallo al subir '+f.name)}}refresh()}
      file.onchange=()=>handle(file.files);
      ['dragenter','dragover'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('hot')}));
      ['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('hot')}));
      drop.addEventListener('drop',ev=>handle(ev.dataTransfer.files));
      refresh(); pollJobs();
    </script></body></html>
    """
  end
end
