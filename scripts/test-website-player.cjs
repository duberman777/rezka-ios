const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../StreamingApp/Features/Player/NativeVideoPlayer.swift'), 'utf8');
const template = source.split('static let template = #"""')[1].split('"""#')[0];

function fixture(startOver = false, initial = {}) {
  let now = 10000, tick;
  const state = {translator: '7', season: '2', episode: '3', ...initial};
  const posts = [], clicks = [], documentEvents = {};
  const listeners = {};
  const video = {
    currentSrc: 'https://cdn.test/episode3.mp4', currentTime: 0, duration: 2400,
    readyState: 1, seeking: false, ended: false, paused: true,
    clientWidth: 640, clientHeight: 360,
    getClientRects: () => [1], setAttribute() {}, scrollIntoView() {},
    addEventListener(event, callback) { (listeners[event] ||= []).push(callback); },
    play() { this.paused = false; return Promise.resolve(); },
    pause() { this.paused = true; for (const fn of listeners.pause || []) fn(); }
  };
  const selectors = {
    '.b-translator__item': ['translator', 'data-translator_id', ['7', '8']],
    '.b-simple_season__item': ['season', 'data-tab_id', ['1', '2']],
    '.b-simple_episode__item': ['episode', 'data-episode_id', ['1', '2', '3', '4', '5']]
  };
  function query(selector) {
    if (selector === 'video') return [video];
    const activeOnly = selector.endsWith('.active');
    const base = activeOnly ? selector.slice(0, -7) : selector;
    const spec = selectors[base];
    if (!spec) return [];
    const [key, attribute, values] = spec;
    return values.filter(value => !activeOnly || state[key] === value).map(value => ({
      getAttribute: name => name === attribute ? value : '',
      getClientRects: () => [1],
      classList: {contains: name => name === 'active' && state[key] === value},
      click() { clicks.push([key, value]); state[key] = value; }
    }));
  }
  const document = {
    querySelectorAll: query, querySelector: selector => query(selector)[0] || null,
    addEventListener: (name, fn) => { documentEvents[name] = fn; }
  };
  const window = {webkit: {messageHandlers: {rezkaProgress: {postMessage: value => posts.push({...value})}}}, addEventListener() {}};
  const context = {window, document, location: {pathname: '/series/test.html'}, Date: {now: () => now}, setInterval: fn => { tick = fn; }};
  const config = {path: '/series/test.html', translator: '7', season: '2', episode: '3', resume: {'2:3': 754.25}, startOver};
  vm.runInNewContext(template.replace('__CONFIG__', JSON.stringify(config)), context);
  return {state, video, posts, clicks, documentEvents, window, tick: () => tick(), advance: ms => { now += ms; }};
}

{
  const f = fixture(false, {episode: '1'});
  assert.equal(f.clicks.length, 1, 'select requested episode through the website control');
  f.advance(1000); f.tick();
  assert.equal(f.posts.length, 0, 'wait for the selected episode source to replace the old video');
  f.video.currentSrc = 'https://cdn.test/selected-episode3.mp4';
  f.tick(); f.tick();
  assert.equal(f.video.currentTime, 754.25);
  assert.equal(f.clicks.length, 1, 'do not repeatedly click the same episode');
}
{
  const f = fixture();
  f.tick();
  assert.equal(f.video.currentTime, 754.25, 'restore fractional seconds');
  assert.equal(f.window.__rezkaSnapshot().episode, '3');
  f.advance(1500); f.video.currentTime = 800; f.video.pause();
  f.video.currentSrc = 'https://cdn.test/episode3-720.mp4'; f.video.currentTime = 0;
  f.tick(); f.tick();
  assert.equal(f.video.currentTime, 800, 'quality switch preserves the recent point');
  f.state.episode = '4'; f.video.currentSrc = 'https://cdn.test/episode4.mp4'; f.video.currentTime = 0;
  f.tick(); f.tick();
  assert.equal(f.clicks.length, 0, 'site autoplay is not forced back to the initial episode');
  assert.equal(f.window.__rezkaSnapshot().episode, '4');
  assert.equal(f.window.__rezkaSnapshot().position, 0);
  assert.equal(f.window.__rezkaSnapshot().season, '2');
  f.video.duration = Infinity;
  assert.equal(f.window.__rezkaSnapshot(), null, 'invalid durations are not saved');
}
{
  const f = fixture(true); f.tick();
  assert.equal(f.video.currentTime, 0, 'Start over overrides existing progress');
  f.advance(1500); f.video.currentTime = 100; f.video.pause();
  f.video.currentSrc = 'https://cdn.test/new-quality.mp4'; f.video.currentTime = 0;
  f.tick(); f.tick();
  assert.equal(f.video.currentTime, 100, 'Start over is applied once, not on each source change');
}
{
  const f = fixture(); f.tick();
  f.state.episode = '5';
  f.documentEvents.click({isTrusted: true, target: {closest: () => ({})}});
  f.advance(1500);
  const count = f.posts.length;
  f.video.pause();
  assert.equal(f.posts.length, count, 'old video must not be saved as the newly selected episode');
  f.video.currentSrc = 'https://cdn.test/episode5.mp4'; f.video.currentTime = 0;
  f.tick(); f.tick();
  assert.equal(f.window.__rezkaSnapshot().episode, '5');
}
console.log('Website bridge tests passed: resume, quality switch, autoplay, Start over, source transition, invalid data.');
