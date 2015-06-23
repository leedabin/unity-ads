package com.unity3d.ads.android.cache;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.net.URLConnection;
import java.util.ArrayList;
import java.util.Vector;

import android.annotation.TargetApi;
import android.os.AsyncTask;
import android.os.Build;
import android.os.SystemClock;

import com.unity3d.ads.android.UnityAdsDeviceLog;
import com.unity3d.ads.android.UnityAdsUtils;
import com.unity3d.ads.android.campaign.UnityAdsCampaign;
import com.unity3d.ads.android.properties.UnityAdsProperties;

@TargetApi(Build.VERSION_CODES.GINGERBREAD)
public class UnityAdsDownloader {
	private static ArrayList<UnityAdsCampaign> _downloadList = null;
	private static ArrayList<IUnityAdsDownloadListener> _downloadListeners = null;
	private static boolean _isDownloading = false;
	private enum UnityAdsDownloadEventType { DownloadCompleted, DownloadCancelled }
	private static Vector<CacheDownload> _cacheDownloads = null;

	public static void addDownload (UnityAdsCampaign downloadCampaign) {
		if (_downloadList == null) _downloadList = new ArrayList<>();
		
		if (!isInDownloads(downloadCampaign.getVideoUrl())) {
			_downloadList.add(downloadCampaign);
		}

		if (!_isDownloading) {
			_isDownloading = true;
			cacheNextFile();
		}
	}

	public static void addListener (IUnityAdsDownloadListener listener) {
		if (_downloadListeners == null) _downloadListeners = new ArrayList<>();
		if (!_downloadListeners.contains(listener))
			_downloadListeners.add(listener);
	}

	public static void removeListener (IUnityAdsDownloadListener listener) {
		if (_downloadListeners == null) return;		
		if (_downloadListeners.contains(listener)) {
			_downloadListeners.remove(listener);
		}
	}

	public static void stopAllDownloads () {
		UnityAdsDeviceLog.entered();
		if (_cacheDownloads != null) {
			for (CacheDownload cd : _cacheDownloads) {
				cd.cancel(true);
			}
		}
	}

	/* INTERNAL METHODS */

	private static void removeDownload (UnityAdsCampaign campaign) {
		if (_downloadList == null) return;
		
		int removeIndex = -1;
		
		for (int i = 0; i < _downloadList.size(); i++) {
			if (_downloadList.get(i).equals(campaign)) {
				removeIndex = i;
				break;
			}
		}
		
		if (removeIndex > -1)
			_downloadList.remove(removeIndex);
	}
	
	private static boolean isInDownloads (String downloadUrl) {
		if (_downloadList != null) {
			for (UnityAdsCampaign download : _downloadList) {
				if (download != null && download.getVideoUrl() != null && download.getVideoUrl().equals(downloadUrl))
					return true;
				else if (download == null || download.getVideoUrl() == null)
					_downloadList.remove(download);
			}
		}
		
		return false;
	}

	private static void sendToListeners (UnityAdsDownloadEventType type, String downloadUrl) {
		if (_downloadListeners == null) return;

		@SuppressWarnings("unchecked")
		ArrayList<IUnityAdsDownloadListener> tmpListeners = (ArrayList<IUnityAdsDownloadListener>)_downloadListeners.clone();

		for (IUnityAdsDownloadListener listener : tmpListeners) {
			switch (type) {
				case DownloadCompleted:
					listener.onFileDownloadCompleted(downloadUrl);
					break;
				case DownloadCancelled:
					listener.onFileDownloadCancelled(downloadUrl);
					break;
			}
		}
	}

	private static void cacheCampaign (UnityAdsCampaign campaign) {
		UnityAdsDeviceLog.debug("Starting download for: " + campaign.getVideoFilename());

		if (campaign.getVideoUrl() != null && campaign.getVideoUrl().length() > 0) {
			CacheDownload cd = new CacheDownload(campaign);
			addToCacheDownloads(cd);
			cd.execute(campaign.getVideoUrl());
		} else {
			removeDownload(campaign);
		}
	}

	private static void cacheNextFile () {
		if (_downloadList != null && _downloadList.size() > 0) {
			cacheCampaign(_downloadList.get(0));
		}
		else if (_downloadList != null) {
			_isDownloading = false;
			UnityAdsDeviceLog.debug("All downloads completed.");
		}
	}

	private static FileOutputStream getOutputStreamFor (String fileName) {
		File tdir = UnityAdsUtils.createCacheDir();
		File outf = new File (tdir, fileName);
		FileOutputStream fos;

		try {
			fos = new FileOutputStream(outf);
		}
		catch (Exception e) {
			UnityAdsDeviceLog.error("Problems creating FOS: " + fileName);
			return null;
		}

		return fos;
	}

	private static void addToCacheDownloads (CacheDownload cd) {
		if (_cacheDownloads == null) 
			_cacheDownloads = new Vector<>();

		_cacheDownloads.add(cd);
	}

	private static void removeFromCacheDownloads (CacheDownload cd) {
		if (_cacheDownloads != null)
			_cacheDownloads.remove(cd);
	}

	/* INTERNAL CLASSES */

	private static class CacheDownload extends AsyncTask<String, Integer, String> {
		private URL _downloadUrl = null;
		private InputStream _input = null;
		private OutputStream _output = null;
		private URLConnection _urlConnection = null;
		private boolean _cancelled = false;
		private UnityAdsCampaign _campaign = null;

		public CacheDownload (UnityAdsCampaign campaign) {
			_campaign = campaign;
		}

		@Override
	    protected String doInBackground(String... sUrl) {
			long startTime = SystemClock.elapsedRealtime();
			long duration;

			try {
				_downloadUrl = new URL(sUrl[0]);
			}
			catch (Exception e) {
				UnityAdsDeviceLog.error("Problems with url: " + e.getMessage());
				onCancelled();
				return null;
			}

			FileOutputStream _fileStream = getOutputStreamFor(_campaign.getVideoFilename());
			if (_fileStream == null) {
				onCancelled();
				return null;
			}
			_output = new BufferedOutputStream(_fileStream);

			try {
				_urlConnection = _downloadUrl.openConnection();
				_urlConnection.setConnectTimeout(10000);
				_urlConnection.setReadTimeout(10000);
				_urlConnection.connect();
			}
			catch (Exception e) {
				UnityAdsDeviceLog.error("Problems opening connection: " + e.getMessage());
			}

			if (_urlConnection != null) {
				try {
					_input = new BufferedInputStream(_urlConnection.getInputStream());
				}
				catch (Exception e) {
					UnityAdsDeviceLog.error("Problems opening stream: " + e.getMessage());
				}

				byte data[] = new byte[4096];
				long total = 0;
				int count;

				try {
					while ((count = _input.read(data)) != -1) {
						total += count;
						_output.write(data, 0, count);
						
						if (_cancelled) {
							return null;
						}
					}
				}
				catch (Exception e) {
					UnityAdsDeviceLog.error("Problems downloading file: " + e.getMessage());
					cancelDownload();
					cacheNextFile();
					return null;
				}

				closeAndFlushConnection();
				duration = SystemClock.elapsedRealtime() - startTime;
				UnityAdsDeviceLog.debug("File: " + _campaign.getVideoFilename() + " of " + total + " bytes downloaded in " + duration + "ms");

				if(duration > 0 && total > 0) {
					// Note about units: bytes / millisecond equals to kilobytes / second so CACHING_SPEED is kb/s
					UnityAdsProperties.CACHING_SPEED = total / duration;
				}
			}

			return null;
		}

		@Override
		protected void onCancelled () {
			UnityAdsDeviceLog.entered();
			_cancelled = true;
			cancelDownload();
		}

		@Override
		protected void onPostExecute(String result) {
        	if (!_cancelled) {
    			removeDownload(_campaign);
            	removeFromCacheDownloads(this);
            	cacheNextFile();

            	String url = "ERROR";
            	if (_downloadUrl != null)
            		url = _downloadUrl.toString();

            	sendToListeners(UnityAdsDownloadEventType.DownloadCompleted, url);
    			super.onPostExecute(result);
        	}
		}

		@Override
	    protected void onPreExecute() {
	        super.onPreExecute();
	    }

	    @Override
	    protected void onProgressUpdate(Integer... progress) {
	        super.onProgressUpdate(progress);
	    }

	    private void closeAndFlushConnection () {			
			try {
				_output.flush();
				_output.close();
				_input.close();
			}
			catch (Exception e) {
				UnityAdsDeviceLog.error("Problems closing connection: " + e.getMessage());
			}	    	
	    }

	    private void cancelDownload () {
        	String url = "ERROR";
        	if (_downloadUrl != null)
        		url = _downloadUrl.toString();

        	UnityAdsDeviceLog.debug("Download cancelled for: " + url);
			closeAndFlushConnection();
			UnityAdsUtils.removeFile(_campaign.getVideoFilename());
        	removeDownload(_campaign);
        	removeFromCacheDownloads(this);
        	sendToListeners(UnityAdsDownloadEventType.DownloadCancelled, url);
	    }
	}
}
