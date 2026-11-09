/* Standalone Now Playing module. No imports, requests, audio or dependencies.
   Classic-script packaging deliberately supports double-click/file:// previews.
   Public API: SoundingPlayer.mount(element), returning {seek, pause, destroy}.
   Artwork, comments, setlist and deterministic waveform adapted from the
   Design/prototypes/now-playing prototype. */
(function () {
  'use strict';
  const mounted = new WeakMap();
  const duration = 3600;
  const speed = 18;
  const comments = [
    [45,'harbourlights','that opening field recording of the pier'],
    [130,'nadia.k','been waiting all week for this one'],
    [238,'orbital_ida','the way Saltwater creeps in under the intro'],
    [300,'Tomás R','volume up, windows down'],
    [412,'kitelines','this bassline is doing something to me'],
    [505,'sleeplessinleeds','first drop and I’m already gone'],
    [560,'Mika Oduya','Lanterns edit!! been hunting this for months'],
    [655,'loop.theory','that filter sweep is so clean'],
    [742,'harbourlights','was front left at Pier Nine, this moment was unreal'],
    [818,'grey_heron','Undertow into this is a lesson in patience'],
    [905,'nadia.k','the strings at 15:05'],
    [962,'dj_wren','Maren never misses on the long build'],
    [1012,'Ruth A.','ID at 17:48 anyone?'],
    [1041,'kitelines','sounds like unreleased Ardent Fields to me'],
    [1068,'Ines Park','this is my whole Sunday sorted'],
    [1102,'orbital_ida','the breakdown here… goosebumps'],
    [1190,'b.ferro','turned it up and the neighbours didn’t complain'],
    [1268,'loop.theory','Glass Tide on repeat after this'],
    [1330,'Tomás R','that vocal chop at 22:10'],
    [1418,'quietfm','perfect blend, can’t hear the seam'],
    [1525,'grey_heron','Cassia Moor dub!! I need this on vinyl'],
    [1640,'sleeplessinleeds','28 minutes in and not one wasted bar'],
    [1755,'Mika Oduya','that low end on a proper system'],
    [1882,'nadia.k','halfway and it only gets better'],
    [1990,'harbourlights','Halfway House at the halfway point. cute.'],
    [2140,'dj_wren','tempo nudge here is so subtle'],
    [2230,'Ruth A.','another ID at 37:02, anyone?'],
    [2290,'quietfm','that pad is like the sea at 5am'],
    [2410,'Sol Mendes','the room went silent for this part'],
    [2505,'kitelines','Sodium Lights club mix. the peak.'],
    [2580,'orbital_ida','42:05 is THE moment'],
    [2690,'Owen L','hands in the air at my desk'],
    [2850,'grey_heron','Long Exposure is such an underrated tune'],
    [3010,'Tomás R','she brought it all the way down'],
    [3215,'nadia.k','Paper Satellites rework!! didn’t see that coming'],
    [3390,'harbourlights','what a closer. thank you Maren'],
    [3520,'Sol Mendes','straight back to the start']
  ];
  const format = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2,'0')}`;
  const spoken = seconds => `${Math.floor(seconds / 60)} minutes ${Math.floor(seconds % 60)} seconds of 60 minutes`;
  const clamp = seconds => Math.max(0, Math.min(duration, Number(seconds) || 0));
  function rng(seed) {
    let s = seed >>> 0;
    return () => {
      s = (s + 0x6d2b79f5) | 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function mount(root) {
    if (mounted.has(root)) return mounted.get(root);
    const find = selector => root.querySelector(selector);
    const scrub = find('[data-np-scrub]');
    const head = find('[data-np-playhead]');
    const time = find('[data-np-time]');
    const play = find('[data-np-play]');
    const bubble = find('[data-np-bubble]');
    const status = find('[data-np-status]');
    const tracklist = find('[data-np-tracklist]');
    const trackButtons = [...root.querySelectorAll('[data-np-track]')];
    const tracks = trackButtons.map(button => ({
      start:Number(button.dataset.npTrack),
      title:button.children[1].firstChild.textContent,
      artist:button.querySelector('small').textContent,
      button
    }));
    const media = matchMedia('(prefers-reduced-motion: reduce)');
    const cleanups = [];
    const on = (target, event, handler) => {
      target.addEventListener(event,handler);
      cleanups.push(() => target.removeEventListener(event,handler));
    };
    let position = clamp(scrub.value);
    let playing = !media.matches;
    let visible = false;
    let frame = 0;
    let previousTime = 0;
    let lastSecond = -1;
    let lastTrack = -1;
    let lastComment = -1;
    let currentTab = 'tracklist';
    let destroyed = false;

    // 225 deterministic, static SVG bars. Only the two reveal layers and
    // playhead transform each frame. No layout reads in the animation loop.
    const wave = find('[data-np-wave]');
    const random = rng(429841);
    const heights = Array.from({length:225},(_,i) => {
      const envelope = .4 + .4 * Math.abs(Math.sin(i*.037)) + .2*Math.abs(Math.cos(i*.19));
      return Math.max(3, (7+random()*53)*envelope);
    });
    const bars = heights.map((height,i) => `<rect x="${i*4}" y="${(70-height)/2}" width="2.5" height="${height}" rx="1.25"/>`).join('');
    wave.innerHTML = bars;
    const reveal = document.createElement('div');
    reveal.className = 'np-wave-reveal';
    reveal.setAttribute('aria-hidden','true');
    const playedWave = wave.parentElement.cloneNode(true);
    playedWave.removeAttribute('aria-hidden');
    playedWave.querySelector('g').removeAttribute('data-np-wave');
    reveal.append(playedWave);
    find('.np-wave-wrap').insertBefore(reveal,head);

    const commentList = find('[data-np-comment-list]');
    comments.forEach(([at,user,text]) => {
      const item = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      const timestamp = document.createElement('time');
      timestamp.textContent = format(at);
      const author = document.createElement('strong');
      author.textContent = user;
      const message = document.createElement('p');
      message.textContent = text;
      button.append(timestamp,author,message);
      button.setAttribute('aria-label',`Jump to ${format(at)}: ${user}, ${text}`);
      on(button,'click',() => seek(at,true));
      item.append(button);
      commentList.append(item);
    });

    function updateButton() {
      root.classList.toggle('is-paused',!playing || media.matches);
      play.setAttribute('aria-label',media.matches ? 'Advance preview by 30 seconds' : playing ? 'Pause preview' : 'Play preview');
      find('.np-speed').textContent = media.matches ? 'STILL PREVIEW' : '18× PREVIEW';
    }
    function showTrack(index) {
      if (index === lastTrack) return;
      if (lastTrack >= 0) tracks[lastTrack].button.removeAttribute('aria-current');
      const track = tracks[index];
      track.button.setAttribute('aria-current','true');
      const title = document.createTextNode(track.title);
      const artist = document.createElement('span');
      artist.textContent = track.artist;
      find('[data-np-current]').replaceChildren(title,artist);
      lastTrack = index;
      // Discrete scroll only when changing tracks. Never scroll the webpage.
      // Do not move a list the user is currently navigating with the keyboard.
      if (currentTab === 'tracklist' && !tracklist.contains(document.activeElement)) {
        const target = track.button.offsetTop - tracklist.offsetTop - tracklist.clientHeight/3;
        tracklist.scrollTop = Math.max(0,target);
      }
    }
    function render() {
      const percent = position/duration*100;
      head.style.transform = `translateX(${percent}%)`;
      reveal.style.transform = `translateX(${percent-100}%)`;
      playedWave.style.transform = `translateX(${100-percent}%)`;
      let commentIndex = comments.length-1;
      while (commentIndex>=0 && comments[commentIndex][0]>position) commentIndex--;
      const comment = comments[commentIndex];
      if (commentIndex !== lastComment) {
        lastComment = commentIndex;
        if (comment) {
          const [at,user,text] = comment;
          bubble.querySelector('.np-avatar').textContent = user.charAt(0);
          const author = bubble.querySelector('.np-comment-user');
          const timestamp = document.createElement('time');
          timestamp.textContent = format(at);
          author.replaceChildren(document.createTextNode(user+' '),timestamp);
          bubble.querySelector('p').textContent = text;
        }
      }
      const age = comment ? position-comment[0] : 111;
      let opacity = Math.min(1, Math.max(0,age/(speed*.3)), Math.max(0,(110-age)/(speed*.25)));
      if (media.matches || !playing) opacity = age<110 ? 1 : 0;
      bubble.style.opacity = String(opacity);
      bubble.style.transform = `translateY(${(1-opacity)*7}px)`;
      const second = Math.floor(position);
      if (second === lastSecond) return;
      lastSecond = second;
      scrub.value = String(second);
      scrub.setAttribute('aria-valuetext',spoken(second));
      time.textContent = format(second);
      let index = tracks.length-1;
      while (index>0 && tracks[index].start>position) index--;
      showTrack(index);
    }
    function tick(now) {
      frame = 0;
      if (!shouldRun()) {
        // Also synchronise at a frame boundary: some embedded/headless hosts
        // expose the new preference before dispatching its change event.
        if (media.matches) { playing=false; updateButton(); render(); }
        return;
      }
      if (previousTime) position += Math.min((now-previousTime)/1000,.1)*speed;
      previousTime = now;
      if (position>=duration) { position=duration; playing=false; updateButton(); }
      render();
      if (shouldRun()) frame=requestAnimationFrame(tick);
    }
    function shouldRun() {
      return !destroyed && playing && visible && !document.hidden && !media.matches;
    }
    function syncLoop() {
      if (media.matches) { playing=false; updateButton(); }
      if (frame) cancelAnimationFrame(frame);
      frame=0;
      previousTime=0;
      if (shouldRun()) frame=requestAnimationFrame(tick);
    }
    function seek(seconds,announce=false) {
      position=clamp(seconds);
      lastSecond=-1;
      previousTime=0;
      render();
      if (announce) status.textContent=`${format(position)}. ${tracks[lastTrack].title} by ${tracks[lastTrack].artist}.`;
    }
    function pause() { playing=false; updateButton(); syncLoop(); render(); }
    function setTab(tab) {
      currentTab=tab.dataset.npTab;
      root.querySelectorAll('[data-np-tab]').forEach(button => {
        const selected=button===tab;
        button.setAttribute('aria-selected',String(selected));
        button.tabIndex=selected?0:-1;
      });
      root.querySelectorAll('[data-np-pane]').forEach(pane => { pane.hidden=pane.dataset.npPane!==currentTab; });
    }
    on(scrub,'input',() => seek(scrub.value));
    on(scrub,'change',() => {status.textContent=`Preview at ${format(position)}.`;});
    on(play,'click',() => {
      if(media.matches) { playing=false; updateButton(); seek(position>=duration?0:position+30,true); return; }
      if(position>=duration) seek(0);
      playing=!playing;
      updateButton(); syncLoop(); render();
      status.textContent=playing?'Silent preview playing.':'Preview paused.';
    });
    on(find('[data-np-prev]'),'click',() => seek(tracks[Math.max(0,lastTrack-1)].start,true));
    on(find('[data-np-next]'),'click',() => seek(tracks[Math.min(tracks.length-1,lastTrack+1)].start,true));
    trackButtons.forEach(button => on(button,'click',() => seek(button.dataset.npTrack,true)));
    const tabs=[...root.querySelectorAll('[data-np-tab]')];
    tabs.forEach((tab,index) => {
      on(tab,'click',() => setTab(tab));
      on(tab,'keydown',event => {
        let next=index;
        if(event.key==='ArrowRight') next=(index+1)%tabs.length;
        else if(event.key==='ArrowLeft') next=(index+tabs.length-1)%tabs.length;
        else if(event.key==='Home') next=0;
        else if(event.key==='End') next=tabs.length-1;
        else return;
        event.preventDefault();setTab(tabs[next]);tabs[next].focus();
      });
    });
    on(document,'visibilitychange',syncLoop);
    on(media,'change',() => {playing=false;updateButton();syncLoop();seek(position);});
    const observer=new IntersectionObserver(entries => {
      visible=entries[0].isIntersecting;
      syncLoop();
    },{threshold:0});
    observer.observe(root);
    root.classList.add('is-ready');
    updateButton();seek(position);
    const api={seek,pause,destroy() {
      destroyed=true;
      syncLoop();observer.disconnect();cleanups.forEach(cleanup=>cleanup());
      reveal.remove();commentList.replaceChildren();root.classList.remove('is-ready');mounted.delete(root);
    }};
    mounted.set(root,api);
    return api;
  }
  window.SoundingPlayer=Object.freeze({mount});
  function init() {document.querySelectorAll('[data-sounding-player]').forEach(mount);}
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init,{once:true});
  else init();
})();
